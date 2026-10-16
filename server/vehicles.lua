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
        if r.stored ~= nil and tonumber(r.stored) == 0 and mig.NotStored == 'impounded' then state = VS.IMPOUNDED end
        local gid
        if r.parking and r.parking ~= '' then
            gid = (Config.ESXParkingMap or {})[tostring(r.parking)] or ('public:' .. tostring(r.parking))
        end
        gid = Utils.ResolveGarageId(gid, plate)
        if state == VS.IMPOUNDED then gid = nil end
        return { plate = plate, owner = r.owner, model = modelFromProps(r.vehicle) or 'unknown', props = r.vehicle,
                 vtype = (r.type == 'boat' and 'boat') or ((r.type == 'airplane' or r.type == 'plane') and 'plane') or (r.type == 'helicopter' and 'heli') or 'automobile',
                 state = state, garage_id = gid, fuel = 100, engine = 1000, body = 1000 }
    else
        local state = (tonumber(r.state) == 2) and VS.IMPOUNDED or VS.GARAGED
        local gid = state == VS.GARAGED and Utils.ResolveGarageId(r.garage and ('public:' .. tostring(r.garage)) or nil, plate) or nil
        return { plate = plate, owner = r.citizenid, model = tostring(r.vehicle or 'unknown'), props = r.mods, vtype = 'automobile',
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

--- Batched upsert. New plates are inserted; existing plates only get their owner updated.
--- Returns inserted count (new rows), transferred count.
function Vehicles.InsertBatch(rows)
    local inserted, transferred, size = 0, 0, (Config.Migration and Config.Migration.BatchSize) or 500
    for i = 1, #rows, size do
        local ph, params, plates, wanted = {}, {}, {}, {}
        for j = i, math.min(i + size - 1, #rows) do
            local r = rows[j]
            ph[#ph + 1] = '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
            -- explicit indices: props/garage_id may be nil (ipairs would stop early)
            local vals = { r.plate, r.owner, r.model, (Config.VehicleTypes or {})[r.model] or r.vtype or 'automobile',
                           r.props, r.state, r.garage_id, r.fuel, r.engine, r.body }
            local base = #params
            for n = 1, 10 do params[base + n] = vals[n] end
            plates[#plates + 1] = r.plate
            wanted[r.plate] = r.owner
        end
        -- previous owners of plates that already exist
        local qs = string.rep('?', #plates, ', ')
        local existing = {}
        for _, e in ipairs(MySQL.query.await('SELECT plate, owner FROM mdp_vehicles WHERE plate IN (' .. qs .. ')', plates) or {}) do
            existing[e.plate] = e.owner
        end
        MySQL.update.await(
            'INSERT INTO mdp_vehicles (plate, owner, model, vtype, props, state, garage_id, fuel, engine, body) VALUES '
            .. table.concat(ph, ', ') .. ' ON DUPLICATE KEY UPDATE owner = VALUES(owner)', params)
        for _, p in ipairs(plates) do
            local old = existing[p]
            if old == nil then inserted = inserted + 1
            elseif old ~= wanted[p] then transferred = transferred + 1; onOwnerChanged(p, old, wanted[p]) end
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
    local rows = MySQL.query.await(q, params) or {}
    local out, skipped = {}, {}
    for _, r in ipairs(rows) do
        local m, why = Vehicles.MapFrameworkRow(framework, r)
        if m and m.owner then out[#out + 1] = m else skipped[why or 'no_owner'] = (skipped[why or 'no_owner'] or 0) + 1 end
    end
    local inserted, transferred = 0, 0
    if #out > 0 then inserted, transferred = Vehicles.InsertBatch(out) end
    return #rows, inserted, skipped, transferred
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
        if #propsJson > 65535 then return false, 'invalid_props' end
    end
    garageId = Utils.ResolveGarageId(garageId or Config.DefaultGarage, plate)
    local vtype = (Config.VehicleTypes or {})[model] or 'automobile'
    local okSel, old = pcall(MySQL.scalar.await, 'SELECT owner FROM mdp_vehicles WHERE plate = ?', { plate })
    if not okSel then return false, 'db_error' end
    local ok = pcall(MySQL.update.await,
        [[INSERT INTO mdp_vehicles (plate, owner, model, vtype, props, state, garage_id) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE owner = VALUES(owner)]],
        { plate, owner, model, vtype, propsJson, VS.GARAGED, garageId })
    if not ok then return false, 'db_error' end
    if old and old ~= owner then onOwnerChanged(plate, old, owner) end
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
    pcall(claimSpawns, src, ident)
    if not Config.SyncFrameworkTables or Bridge.Framework == 'standalone' then return end
    local now = GetGameTimer()
    if not force and lastSync[ident] and now - lastSync[ident] < 60000 then return end
    lastSync[ident] = now
    local ok, read, inserted, _, transferred = pcall(Vehicles.ImportFromFramework, Bridge.Framework, ident)
    if not ok then print('^1[mdp_garages] sync failed for ' .. ident .. ': ' .. tostring(read) .. '^0') return end
    if inserted > 0 or (transferred or 0) > 0 then
        print(('[mdp_garages] synced %s: %d read, %d new, %d transferred'):format(ident, read, inserted, transferred or 0))
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
