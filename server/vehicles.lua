-- mdp_vehicles is the source of truth. This module:
--  * imports rows from framework tables (owned_vehicles / player_vehicles), batched upsert, originals untouched
--    (INSERT ... ON DUPLICATE KEY UPDATE owner: framework ownership changes propagate; previous owner's keys revoked)
--  * syncs on player load, on resource start for connected players, and lazily in getVehicles (60 s cache)
--  * exposes export AddVehicle for dealerships
MDP.Vehicles = {}
local Vehicles = MDP.Vehicles
local VS = Constants.VehicleState

local schemaCache = {}
local function tableExists(name)
    local key = 't:' .. name
    if schemaCache[key] == nil then
        schemaCache[key] = MySQL.scalar.await(
            'SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ? LIMIT 1', { name }) ~= nil
    end
    return schemaCache[key]
end

local function columnExists(tbl, col)
    local key = 'c:' .. tbl .. '.' .. col
    if schemaCache[key] == nil then
        schemaCache[key] = MySQL.scalar.await(
            'SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ? LIMIT 1',
            { tbl, col }) ~= nil
    end
    return schemaCache[key]
end
Vehicles.TableExists, Vehicles.ColumnExists = tableExists, columnExists

-- L2: framework props above 16 KB are not imported (they would be replicated by state bag)
local function capProps(raw, plate)
    if type(raw) == 'string' and #raw > 16384 then
        print(('^3[mdp_garages] import: props of %s exceed 16 KB, not imported^0'):format(tostring(plate))); return nil
    end
    return raw
end

local function modelFromProps(raw)
    local ok, props = pcall(json.decode, raw or '{}')
    if ok and type(props) == 'table' and props.model then return tostring(props.model) end
    return nil
end

--- Normalize one framework row into an mdp_vehicles row, or nil + skip reason.
--- framework: 'esx' | 'qb'
function Vehicles.MapFrameworkRow(framework, r)
    local mig = Config.Migration or {}
    local plate = Utils.NormalizePlate(r.plate)
    if not Utils.IsValidPlate(plate) then return nil, 'invalid_plate' end
    if framework == 'esx' then
        if r.type ~= nil and not (mig.VehicleTypes or { car = true })[tostring(r.type)] then return nil, 'type' end
        if mig.SkipJobVehicles ~= false and r.job ~= nil and r.job ~= '' and r.job ~= 'civ' then return nil, 'job' end
        local state = VS.GARAGED
        if r.stored ~= nil and tonumber(r.stored) == 0 then
            -- not stored: 'out' (default; storable via storeVehicle, R3-1) | 'impounded' | 'garaged'
            if mig.NotStored == 'impounded' then state = VS.IMPOUNDED
            elseif mig.NotStored ~= 'garaged' then state = VS.OUT end
        end
        local gid
        if r.parking and r.parking ~= '' then
            gid = (Config.ESXParkingMap or {})[tostring(r.parking)] or ('public:' .. tostring(r.parking))
        end
        gid = Utils.ResolveGarageId(gid, plate)
        if state == VS.IMPOUNDED then gid = nil end
        return { plate = plate, owner = r.owner, model = modelFromProps(r.vehicle) or 'unknown', props = capProps(r.vehicle, plate),
                 vtype = (r.type == 'boat' and 'boat') or ((r.type == 'airplane' or r.type == 'plane') and 'plane') or (r.type == 'helicopter' and 'heli') or 'automobile',
                 state = state, garage_id = gid, fuel = 100, engine = 1000, body = 1000 }
    else
        -- QB state: 0 out (e.g. just bought, storable via storeVehicle), 1 garaged, 2 impounded
        local qs = tonumber(r.state)
        local state = (qs == 2 and VS.IMPOUNDED) or (qs == 0 and VS.OUT) or VS.GARAGED
        local gid = state ~= VS.IMPOUNDED and Utils.ResolveGarageId(r.garage and ('public:' .. tostring(r.garage)) or nil, plate) or nil
        return { plate = plate, owner = r.citizenid, model = tostring(r.vehicle or 'unknown'), props = capProps(r.mods, plate), vtype = 'automobile',
                 state = state, garage_id = gid, fuel = tonumber(r.fuel) or 100,
                 engine = tonumber(r.engine) or 1000, body = tonumber(r.body) or 1000 }
    end
end

--- Batched INSERT IGNORE. Returns inserted count.
--- Owner-change handling: revoke all keys of the plate and log (QA N3).
local function onOwnerChanged(plate, oldOwner, newOwner)
    MySQL.update.await('DELETE FROM mdp_vehicle_keys WHERE plate = ?', { plate })
    print(('^3[mdp_garages] owner of %s changed %s -> %s (framework sync); keys revoked^0'):format(plate, tostring(oldOwner), tostring(newOwner)))
end
Vehicles.OnOwnerChanged = onOwnerChanged

--- Diff-based apply (QA R3-2/R3-3): only NEW plates are inserted; plates whose owner differs are transferred
--- only when the mdp row is GARAGED or PARKED_WORLD (1/2). OUT (0) / IMPOUNDED (3) are logged and retried next sync.
--- Unchanged rows cause no writes. Returns inserted, transferred.
function Vehicles.InsertBatch(rows)
    local inserted, transferred, size = 0, 0, (Config.Migration and Config.Migration.BatchSize) or 500
    for i = 1, #rows, size do
        local chunk, plates = {}, {}
        for j = i, math.min(i + size - 1, #rows) do chunk[#chunk + 1] = rows[j]; plates[#plates + 1] = rows[j].plate end
        local existing = {}
        local qs = string.rep('?', #plates, ', ')
        for _, e in ipairs(MySQL.query.await('SELECT plate, owner, state FROM mdp_vehicles WHERE plate IN (' .. qs .. ')', plates) or {}) do
            existing[e.plate] = e
        end
        local ph, params = {}, {}
        local worldPlates -- lazy: normalized plate -> entity, only if some new row is OUT
        for _, r in ipairs(chunk) do
            local e = existing[r.plate]
            -- R4-1: an imported OUT row without a live entity would be stuck -> GARAGED in its garage
            if r.state == VS.OUT and (not e or tonumber(e.state) == VS.REMOVED) then
                worldPlates = worldPlates or Utils.WorldVehiclesByPlate()
                -- R6-1: any match (one or ambiguous duplicates) keeps OUT; only zero matches -> GARAGED
                local _, matches = Utils.UniqueWorldVehicle(worldPlates, r.plate, Utils.ModelHash(r.model))
                if matches == 0 then
                    r.state = VS.GARAGED
                    r.garage_id = r.garage_id or Config.DefaultGarage
                end
            end
            if e and tonumber(e.state) == VS.REMOVED then
                -- plate reappeared in the framework: restore (owner may have changed)
                local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, owner = ?, garage_id = ? WHERE plate = ? AND state = ?',
                    { r.state == VS.OUT and VS.OUT or VS.GARAGED, r.owner, r.garage_id or Config.DefaultGarage, r.plate, VS.REMOVED })
                if n == 1 then
                    -- R5-4: a restored vehicle never keeps old shared keys (same or new owner)
                    MySQL.update.await('DELETE FROM mdp_vehicle_keys WHERE plate = ?', { r.plate })
                    print(('^3[mdp_garages] %s restored from REMOVED (reappeared in framework for %s); shared keys cleared^0'):format(r.plate, tostring(r.owner)))
                    inserted = inserted + 1
                end
            elseif not e then
                ph[#ph + 1] = "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'framework')"
                -- explicit indices: props/garage_id may be nil (ipairs would stop early)
                local vals = { r.plate, r.owner, r.model, (Config.VehicleTypes or {})[r.model] or r.vtype or 'automobile',
                               r.props, r.state, r.garage_id, r.fuel, r.engine, r.body }
                local base = #params
                for n = 1, 10 do params[base + n] = vals[n] end
            elseif e.owner ~= r.owner then
                local st = tonumber(e.state)
                if st == VS.GARAGED or st == VS.PARKED_WORLD then
                    local n = MySQL.update.await('UPDATE mdp_vehicles SET owner = ? WHERE plate = ? AND owner = ? AND state IN (?, ?)',
                        { r.owner, r.plate, e.owner, VS.GARAGED, VS.PARKED_WORLD })
                    if n == 1 then transferred = transferred + 1; onOwnerChanged(r.plate, e.owner, r.owner) end
                else
                    print(('^3[mdp_garages] owner change for %s (%s -> %s) deferred: vehicle is in state %s; retried next sync^0')
                        :format(r.plate, tostring(e.owner), tostring(r.owner), tostring(st)))
                end
            end
        end
        if #ph > 0 then
            inserted = inserted + (MySQL.update.await(
                'INSERT IGNORE INTO mdp_vehicles (plate, owner, model, vtype, props, state, garage_id, fuel, engine, body, source) VALUES '
                .. table.concat(ph, ', '), params) or 0)
        end
    end
    return inserted, transferred
end

--- Select framework rows (optionally for one owner), map, insert. Returns read, inserted, skipped{reason=n}.
function Vehicles.ImportFromFramework(framework, owner)
    local tbl, ownerCol, cols
    if framework == 'esx' then
        tbl, ownerCol = 'owned_vehicles', 'owner'
        cols = { 'owner', 'plate', 'vehicle' }
        for _, c in ipairs({ 'type', 'job', 'stored', 'parking' }) do
            if columnExists(tbl, c) then cols[#cols + 1] = c end
        end
    elseif framework == 'qb' or framework == 'qbx' then
        framework, tbl, ownerCol = 'qb', 'player_vehicles', 'citizenid'
        cols = { 'citizenid', 'plate', 'vehicle', 'mods' }
        for _, c in ipairs({ 'garage', 'fuel', 'engine', 'body', 'state' }) do
            if columnExists(tbl, c) then cols[#cols + 1] = c end
        end
    else
        return 0, 0, {}
    end
    if not tableExists(tbl) then return 0, 0, {} end
    -- identifiers are fixed literals above, never user input
    local q = ('SELECT `%s` FROM `%s`'):format(table.concat(cols, '`, `'), tbl)
    local params = {}
    if owner then q = q .. (' WHERE `%s` = ?'):format(ownerCol); params[1] = owner end
    local okQ, rows = pcall(MySQL.query.await, q, params)
    if not okQ or type(rows) ~= 'table' then
        print(('^1[mdp_garages] framework query failed on %s: %s^0'):format(tbl, tostring(rows)))
        return 0, 0, {}, 0, false
    end
    local out, skipped = {}, {}
    for _, r in ipairs(rows) do
        local m, why = Vehicles.MapFrameworkRow(framework, r)
        if m and m.owner then out[#out + 1] = m else skipped[why or 'no_owner'] = (skipped[why or 'no_owner'] or 0) + 1 end
    end
    local inserted, transferred = 0, 0
    if #out > 0 then inserted, transferred = Vehicles.InsertBatch(out) end
    local removed = 0
    if owner and Config.SyncRemovals then removed = Vehicles.SyncRemovals(tbl, ownerCol, owner, rows) end
    return #rows, inserted, skipped, transferred, true, removed
end

--- Config.SyncRemovals: delete this owner's framework-sourced rows whose plate disappeared from the framework table.
--- Safety: only source='framework' rows; only after a successful query of an existing table (caller);
--- zero framework rows while we hold framework-sourced vehicles = possible transient issue -> warn and skip.
--- If the plate still exists in the framework under another owner, it is transferred instead of deleted.
function Vehicles.SyncRemovals(tbl, ownerCol, owner, frameworkRows)
    local present = {}
    for _, r in ipairs(frameworkRows) do
        local p = Utils.NormalizePlate(r.plate)
        if p then present[p] = true end
    end
    local mine = MySQL.query.await("SELECT plate FROM mdp_vehicles WHERE owner = ? AND source = 'framework' AND state <> ?",
        { owner, VS.REMOVED }) or {}
    if #mine == 0 then return 0 end
    if #frameworkRows == 0 then
        print(('^3[mdp_garages] sync removals skipped for %s: framework table returned 0 rows but %d framework-sourced vehicles exist (transient?)^0')
            :format(owner, #mine))
        return 0
    end
    local removed = 0
    for _, m in ipairs(mine) do
        local plate = m.plate
        if not present[plate] then
            -- identifiers are fixed literals (tbl/ownerCol chosen in ImportFromFramework), never user input
            local other = MySQL.scalar.await(('SELECT `%s` FROM `%s` WHERE UPPER(TRIM(`plate`)) = ? LIMIT 1'):format(ownerCol, tbl), { plate })
            pcall(Security.WithLock, plate, 0, function()
                if other and other ~= owner then
                    local n = MySQL.update.await("UPDATE mdp_vehicles SET owner = ? WHERE plate = ? AND owner = ? AND source = 'framework' AND state IN (?, ?)",
                        { other, plate, owner, VS.GARAGED, VS.PARKED_WORLD })
                    if n == 1 then onOwnerChanged(plate, owner, other) end
                    return
                end
                local ent = Security.GetSpawnedEntity(plate)
                -- R3b-2: never despawn with someone inside; defer to the next sync
                if ent and not Utils.IsVehicleEmpty(ent) then
                    print(('^3[mdp_garages] removal of %s deferred: vehicle occupied; retried next sync^0'):format(plate))
                    return
                end
                -- R3b-1: SOFT delete (state 5 REMOVED). Fines/impound/keys rows are kept (fines are tied to owner).
                local n = MySQL.update.await("UPDATE mdp_vehicles SET state = ?, coords = NULL, parked_at = NULL WHERE plate = ? AND owner = ? AND source = 'framework' AND state <> ?",
                    { VS.REMOVED, plate, owner, VS.REMOVED })
                if n == 1 then
                    if ent then Security.UntrackSpawn(plate); DeleteEntity(ent) end
                    removed = removed + 1
                    print(('^3[mdp_garages] %s marked REMOVED: no longer in %s for %s (fines kept)^0'):format(plate, tbl, owner))
                end
            end)
        end
    end
    return removed
end

---------------------------------------------------------------------------
-- Export for dealerships: exports.mdp_garages:AddVehicle(owner, plate, model, props?, garageId?)
-- Returns ok:boolean, err?:string ('invalid_owner'|'invalid_plate'|'invalid_model'|'invalid_props'|'plate_exists'|'db_error')
---------------------------------------------------------------------------
function Vehicles.AddVehicle(owner, plate, model, props, garageId)
    if type(owner) ~= 'string' or owner == '' or #owner > 64 then return false, 'invalid_owner' end
    plate = Utils.NormalizePlate(plate)
    if not Utils.IsValidPlate(plate) then return false, 'invalid_plate' end
    if type(model) == 'number' then model = tostring(math.tointeger(model) or model) end
    if type(model) ~= 'string' or #model > 64 or not (model:match('^[%w_]+$') or model:match('^%-?%d+$')) then return false, 'invalid_model' end
    local propsJson
    if props ~= nil then
        if type(props) == 'table' then propsJson = json.encode(props)
        elseif type(props) == 'string' then propsJson = props
        else return false, 'invalid_props' end
        if #propsJson > 16384 then return false, 'invalid_props' end -- L1: same cap as the replicated state bag
        if Security.SanitizeProps then
            local okD, t = pcall(json.decode, propsJson)
            local clean, _, enc
            if okD and type(t) == 'table' then clean, _, enc = Security.SanitizeProps(t, { plate = plate, model = model }) end
            if not clean then return false, 'invalid_props' end
            propsJson = enc
        end
    end
    -- garageId = 'out': the vehicle is already spawned in the world (e.g. dealership test-drive/delivery)
    local initialState = VS.GARAGED
    if garageId == 'out' then initialState, garageId = VS.OUT, nil end
    garageId = Utils.ResolveGarageId(garageId or Config.DefaultGarage, plate)
    local vtype = (Config.VehicleTypes or {})[model] or 'automobile'
    local okSel, cur = pcall(MySQL.single.await, 'SELECT owner, state FROM mdp_vehicles WHERE plate = ?', { plate })
    if not okSel then return false, 'db_error' end
    local old = cur and cur.owner
    if not cur then
        local ok = pcall(MySQL.update.await,
            [[INSERT IGNORE INTO mdp_vehicles (plate, owner, model, vtype, props, state, garage_id, source)
              VALUES (?, ?, ?, ?, ?, ?, ?, 'mdp')]], { plate, owner, model, vtype, propsJson, initialState, garageId })
        if not ok then return false, 'db_error' end
    elseif tonumber(cur.state) == VS.REMOVED then
        -- R5-1: restore a soft-deleted vehicle for the (new) owner; R5-4: clear old shared keys
        local okR, n = pcall(MySQL.update.await, [[UPDATE mdp_vehicles SET state = ?, owner = ?, garage_id = ?, model = ?, vtype = ?,
            props = COALESCE(?, props), source = 'mdp', coords = NULL, parked_at = NULL WHERE plate = ? AND state = ?]],
            { initialState, owner, garageId, model, vtype, propsJson, plate, VS.REMOVED })
        if not okR then return false, 'db_error' end
        if n ~= 1 then return false, 'transfer_deferred' end
        -- R6-2: key cleanup must not throw after the restore is done
        local okK, errK = pcall(MySQL.update.await, 'DELETE FROM mdp_vehicle_keys WHERE plate = ?', { plate })
        if not okK then print(('^1[mdp_garages] %s restored but clearing shared keys failed: %s^0'):format(plate, tostring(errK))) end
        print(('^3[mdp_garages] %s restored from REMOVED by AddVehicle for %s (was %s); shared keys cleared^0'):format(plate, owner, tostring(old)))
        local src = Vehicles.FindSourceByIdentifier and Vehicles.FindSourceByIdentifier(owner)
        if src then CreateThread(function() Vehicles.SyncPlayer(src, true) end) end
        return true, 'restored'
    elseif old ~= owner then
        -- R3-3: transfer only when garaged / world-parked
        local okU, n = pcall(MySQL.update.await, 'UPDATE mdp_vehicles SET owner = ? WHERE plate = ? AND owner = ? AND state IN (?, ?)',
            { owner, plate, old, VS.GARAGED, VS.PARKED_WORLD })
        if not okU then return false, 'db_error' end
        if n ~= 1 then return false, 'transfer_deferred' end
        onOwnerChanged(plate, old, owner)
    end
    -- also sync the owner's other framework vehicles if they are online (QA N7)
    local src = Vehicles.FindSourceByIdentifier and Vehicles.FindSourceByIdentifier(owner)
    if src then CreateThread(function() Vehicles.SyncPlayer(src, true) end) end
    return true, (old and old ~= owner) and 'transferred' or (old and 'exists' or nil)
end
exports('AddVehicle', Vehicles.AddVehicle)

---------------------------------------------------------------------------
-- Sync on player load (per framework event)
---------------------------------------------------------------------------
--- Reconnect: hand the player's still-tracked vehicles back to them (Security.ClaimSpawn).
local function claimSpawns(src, ident)
    local rows = MySQL.query.await('SELECT plate FROM mdp_vehicles WHERE owner = ? AND state IN (?, ?)',
        { ident, VS.OUT, VS.PARKED_WORLD }) or {}
    for _, r in ipairs(rows) do
        if Security.GetSpawnedEntity(r.plate) then Security.ClaimSpawn(r.plate, src) end
    end
end

local lastSync = {} -- identifier -> GetGameTimer() of last framework sync

function Vehicles.FindSourceByIdentifier(ident)
    if Bridge.GetSourceByIdentifier then return Bridge.GetSourceByIdentifier(ident) end -- R3-8 reverse map
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src and Bridge.GetIdentifier(src) == ident then return src end
    end
    return nil
end

--- force = ignore the 60 s cache (player load, AddVehicle, startup)
local function syncPlayer(src, force)
    local ident = Bridge.GetIdentifier(src)
    if not ident then return end
    if force then pcall(claimSpawns, src, ident) end -- R3-2: only on load/start/AddVehicle, not on every garage open
    if not Config.SyncFrameworkTables or Bridge.Framework == 'standalone' then return end
    local now = GetGameTimer()
    if not force and lastSync[ident] and now - lastSync[ident] < 60000 then return end
    lastSync[ident] = now
    local ok, read, inserted, _, transferred, _, removed = pcall(Vehicles.ImportFromFramework, Bridge.Framework, ident)
    if not ok then print('^1[mdp_garages] sync failed for ' .. ident .. ': ' .. tostring(read) .. '^0') return end
    if inserted > 0 or (transferred or 0) > 0 or (removed or 0) > 0 then
        print(('[mdp_garages] synced %s: %d read, %d new, %d transferred, %d removed'):format(ident, read, inserted, transferred or 0, removed or 0))
    end
end
Vehicles.SyncPlayer = syncPlayer

if Bridge.Framework == 'esx' then
    AddEventHandler('esx:playerLoaded', function(playerId) CreateThread(function() syncPlayer(playerId, true) end) end)
elseif Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
    AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
        local src = player and player.PlayerData and player.PlayerData.source
        if src then CreateThread(function() syncPlayer(src, true) end) end
    end)
end

--- Called by persistence.lua after startup recovery: sync everyone already connected (resource restart).
function Vehicles.SyncConnectedPlayers()
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src then pcall(syncPlayer, src, true) end
    end
end
