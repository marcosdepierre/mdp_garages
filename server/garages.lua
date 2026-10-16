-- Garage callbacks used by the NUI (client proxies them 1:1). Responses: { ok, error?, data? }.
local VS = Constants.VehicleState
local GARAGE_KINDS = { public = true, private = true }           -- takeOut / storeVehicle
local LIST_KINDS = { public = true, private = true, impound = true } -- getVehicles (impound: show only, release is phase 5)

local function listCoords(_, data)
    local g = Utils.GetGarage(data and data.garage_id, LIST_KINDS)
    return g and g.coords or nil
end

local function garageCoords(_, data)
    local g = Utils.GetGarage(data and data.garage_id, GARAGE_KINDS)
    return g and g.coords or nil
end

--- Vehicles the player owns or holds keys for, shaped per the NUI contract.
local function listVehicles(src, garage)
    local ident = Bridge.GetIdentifier(src)
    if not ident then return nil end
    local rows = MySQL.query.await([[
        SELECT v.plate, v.owner, v.model, v.vtype, v.coords, v.state, v.fuel, v.engine, v.body, v.mileage, v.garage_id
        FROM mdp_vehicles v
        WHERE (v.owner = ? OR v.plate IN (SELECT k.plate FROM mdp_vehicle_keys k WHERE k.holder = ?)) AND v.state <> ?]],
        { ident, ident, VS.REMOVED }) or {}
    local out = {}
    for _, r in ipairs(rows) do
      -- type filter (QA N10): vehicles whose type this garage cannot hold are NOT listed at all
      local vtype = Utils.IsValidVehicleType(r.vtype) and r.vtype or 'automobile'
      if Utils.GarageAllowsType(garage, vtype) then
        local isOwner = r.owner == ident
        local mileage, unit = Utils.FormatMileage(tonumber(r.mileage) or 0)
        local v = {
            plate = r.plate, model = r.model, label = r.model, state = tonumber(r.state) or 0,
            fuel = tonumber(r.fuel) or 0, engine = tonumber(r.engine) or 0, body = tonumber(r.body) or 0,
            mileage = mileage, mileage_unit = unit, garage_id = r.garage_id, is_owner = isOwner,
        }
        if r.coords and (isOwner or Config.KeyHoldersSeeLocation) then
            local ok, c = pcall(json.decode, r.coords)
            if ok and type(c) == 'table' then v.coords = { x = c.x, y = c.y, z = c.z } end
        end
        v.vtype = vtype
        out[#out + 1] = v
      end
    end
    return out
end

MDP.Callback('mdp_garages:getVehicles', {
    rateLimit = { max = 5, windowMs = 10000 },
    schema = { garage_id = Security.V.isGarageId },
    distance = { getCoords = listCoords, max = Config.MaxGarageDistance },
}, function(src, data)
    local garage, err = Utils.GetGarage(data.garage_id, LIST_KINDS)
    if not garage then return { ok = false, error = err } end
    CreateThread(function() MDP.Vehicles.SyncPlayer(src) end) -- lazy framework sync, 60 s cache, non-blocking (R3-2)
    local list = listVehicles(src, garage)
    if not list then return { ok = false, error = 'invalid_source' } end
    return { ok = true, data = list }
end)

local function isSpawnFree(spawn)
    for _, veh in ipairs(GetAllVehicles()) do
        local c = GetEntityCoords(veh)
        if #(c - vec3(spawn.x, spawn.y, spawn.z)) < 3.0 then return false end
    end
    return true
end

--- M6: the fine block checks the vehicle OWNER (a key holder can't bypass the owner's fines)
local function unpaidFinesBlocked(owner)
    if not Config.BlockOnUnpaidFines or not owner then return false end
    -- only real unpaid fines: needs_review (possibly already paid via invoice) does not count (QA N8)
    local n = MySQL.scalar.await("SELECT COUNT(*) FROM mdp_fines WHERE owner = ? AND paid = ? AND channel IN ('internal', 'invoice')",
        { owner, Constants.FineStatus.UNPAID })
    return (tonumber(n) or 0) >= (Config.UnpaidFinesThreshold or 1)
end

local function vehicleOccupied(veh)
    for seat = -1, (GetVehicleMaxNumberOfPassengers and GetVehicleMaxNumberOfPassengers(veh) or 6) - 1 do
        local ped = GetPedInVehicleSeat(veh, seat)
        if ped and ped ~= 0 then return true end
    end
    return false
end

MDP.Callback('mdp_garages:takeOut', {
    rateLimit = { max = 1, windowMs = 1000 },
    schema = { plate = 'plate', garage_id = Security.V.isGarageId },
    requireOwnership = true, -- owner or key holder
    distance = { getCoords = garageCoords, max = Config.MaxGarageDistance },
}, function(src, data)
    local garage, gerr = Utils.GetGarage(data.garage_id, GARAGE_KINDS)
    if not garage then return { ok = false, error = gerr } end
    local plate = data.plate -- already normalized by ValidateSchema
    local res = table.pack(Security.WithLock(plate, src, function()
        -- everything re-read inside the lock
        local row = MySQL.single.await([[SELECT plate, owner, model, vtype, props, state, garage_id, coords, heading, parked_at,
            fuel, engine, body, mileage FROM mdp_vehicles WHERE plate = ?]], { plate })
        if not row or tonumber(row.state) == VS.REMOVED then return { ok = false, error = 'not_found' } end
        local state = tonumber(row.state)
        if state == VS.RETIRED then return { ok = false, error = 'retired' } end
        if state == VS.IMPOUNDED then return { ok = false, error = 'impounded' } end -- paid release: phase 5
        -- PARKED_WORLD take-out kept in phase 1 as 'bring my car' (the streamer only spawns in place)
        if state ~= VS.GARAGED and state ~= VS.PARKED_WORLD then return { ok = false, error = 'already_out' } end
        if state == VS.GARAGED and row.garage_id ~= data.garage_id then return { ok = false, error = 'wrong_garage' } end
        local vtype = Utils.IsValidVehicleType(row.vtype) and row.vtype or 'automobile'
        if not Utils.GarageAllowsType(garage, vtype) then return { ok = false, error = 'wrong_vehicle_type' } end
        if unpaidFinesBlocked(row.owner) then return { ok = false, error = 'unpaid_fines' } end
        local tracked = Security.GetSpawnedEntity(plate)
        if tracked then
            if state ~= VS.PARKED_WORLD then return { ok = false, error = 'already_out' } end
            if vehicleOccupied(tracked) then return { ok = false, error = 'in_use' } end -- R3-4
            local okC, c = pcall(json.decode, row.coords or '')
            if okC and type(c) == 'table' and c.x and #(GetEntityCoords(tracked) - vec3(c.x, c.y, c.z)) > (Config.ParkedMoveTolerance or 5.0) then
                return { ok = false, error = 'vehicle_moved' }
            end
        end
        local spawn
        for _, sp in ipairs(garage.spawns or {}) do if isSpawnFree(sp) then spawn = sp break end end
        if not spawn then return { ok = false, error = 'no_spawn' } end
        -- conditional transition on the state we read; affectedRows checked
        local affected
        if state == VS.GARAGED then
            affected = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, parked_at = NULL WHERE plate = ? AND state = ? AND garage_id = ?',
                { VS.OUT, plate, VS.GARAGED, data.garage_id })
        else
            affected = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, parked_at = NULL WHERE plate = ? AND state = ?',
                { VS.OUT, plate, VS.PARKED_WORLD })
        end
        if affected ~= 1 then return { ok = false, error = 'already_out' } end
        -- M1: the old world entity is deleted only after the UPDATE succeeded
        if tracked then
            Security.UntrackSpawn(plate)
            DeleteEntity(tracked)
            MDP.Streamer.Forget(plate)
        end
        row.vtype = vtype
        local veh, netId = MDP.Props.SpawnVehicle(row, spawn.x, spawn.y, spawn.z, spawn.w, src) -- pcall inside (H1)
        if not veh then
            -- H1/M2: roll back to the EXACT previous state (garage + garage_id, or parked + coords/heading)
            if state == VS.GARAGED then
                MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ? WHERE plate = ? AND state = ?',
                    { VS.GARAGED, row.garage_id, plate, VS.OUT })
            else
                MySQL.update.await('UPDATE mdp_vehicles SET state = ?, coords = ?, heading = ?, parked_at = COALESCE(?, CURRENT_TIMESTAMP) WHERE plate = ? AND state = ?',
                    { VS.PARKED_WORLD, row.coords, row.heading, row.parked_at, plate, VS.OUT })
                MDP.Streamer.Track(plate)
            end
            return { ok = false, error = 'spawn_failed' }
        end
        if state == VS.PARKED_WORLD then MySQL.update.await('UPDATE mdp_vehicles SET coords = NULL WHERE plate = ? AND state = ?', { plate, VS.OUT }) end
        MDP.Props.GiveKeys(src, veh, plate) -- after TrackSpawn / entity exists
        MDP.Props.Hook(Bridge.FrameworkSync, 'OnSpawn', plate)
        return { ok = true, data = { netId = netId } }
    end))
    local r = res[1]
    if r == false then return { ok = false, error = res[2] or 'locked' } end
    return r
end)

---------------------------------------------------------------------------
-- storeVehicle: plate ALWAYS read server-side from the entity; client may only hint the GTA class.
---------------------------------------------------------------------------
local NATIVE_TYPE = { automobile = 'automobile', bike = 'bike', quadbike = 'automobile', amphibious_automobile = 'automobile',
    amphibious_quadbike = 'automobile', boat = 'boat', submarine = 'boat', heli = 'heli', blimp = 'heli', plane = 'plane' }

--- Type resolution: Config.VehicleTypes[model] > server GetVehicleType(entity) > client class hint > automobile.
local function resolveVehicleType(veh, model, clientClass)
    local override = (Config.VehicleTypes or {})[model]
    if Utils.IsValidVehicleType(override) then return override end
    if GetVehicleType then
        local ok, t = pcall(GetVehicleType, veh)
        if ok and t and NATIVE_TYPE[t] then return NATIVE_TYPE[t] end
    end
    if clientClass ~= nil then return Utils.VehicleTypeFromClass(clientClass) end
    return 'automobile'
end

--- Shared resolver for every netId-based handler (store, parkWorld, tow, fine, impound, syncWear).
function MDP.Vehicles.ResolvePlateFromNetId(_, data)
    -- R4-3: netId must be an integer (5.0 -> 5); PlateFromNetId/TrackSpawn require math.type 'integer'
    local netId = data and math.tointeger(data.netId)
    if not netId then return nil, 'bad_netid' end
    data.netId = netId
    local plate, err = Security.PlateFromNetId(netId)
    return plate, err
end


local PROPS_SCHEMA = {
    props = Security.Optional(function(v) return type(v) == 'table' end), -- lib.getVehicleProperties (SanitizeProps below)
    fuel = Security.Optional(function(v) return type(v) == 'number' and v == v end),
    mileage = Security.Optional(function(v) return type(v) == 'number' and v == v and v >= 0 end), -- km
}
local function schemaWith(base)
    for k, v in pairs(PROPS_SCHEMA) do base[k] = v end
    return base
end

--- Store/park: the plate comes from the server mark / tracking, NEVER from the client's plate text.
--- Candidate = mdp_plate bag (forgeable) -> proven by Security.IsServerEntity (secret, non-replicated tag) + tracking.
local function candidatePlate(ent)
    local p = Entity(ent).state.mdp_plate
    p = type(p) == 'string' and Utils.NormalizePlate(p) or nil
    return (p and Utils.IsValidPlate(p)) and p or nil
end

--- Local twin of Security.CanStoreOwnVehicle(src, ent, opts) -> ok, plate | false, err (same error names):
--- not_server_entity, plate_mismatch, not_tracked, not_owner, wrong_state, model_mismatch, too_far.
--- opts = { plate, row, maxDistance, allowDriver, allowKeys }. Must run INSIDE the plate lock with a fresh row.
local function localCanStoreOwnVehicle(src, ent, opts)
    local plate = opts.plate
    if not plate or not Security.IsServerEntity(ent, plate) then return false, 'not_server_entity' end
    local text = Utils.NormalizePlate(GetVehicleNumberPlateText(ent) or '')
    if text ~= plate then return false, 'plate_mismatch' end
    if Security.GetSpawnedEntity(plate) ~= ent then return false, 'not_tracked' end
    local row = opts.row
    if not row or not Security.IsOwner(src, plate, opts.allowKeys == true) then return false, 'not_owner' end
    if tonumber(row.state) ~= VS.OUT then return false, 'wrong_state' end
    if not Utils.SameModel(GetEntityModel(ent), Utils.ModelHash(row.model)) then return false, 'model_mismatch' end
    local isDriver = opts.allowDriver and GetPedInVehicleSeat(ent, -1) == GetPlayerPed(src)
    if not isDriver and not Security.IsNear(src, GetEntityCoords(ent), opts.maxDistance or Config.MaxVehicleDistance) then
        return false, 'too_far'
    end
    return true, plate
end

local STORE_ERR = { not_owner = 'not_owner', wrong_state = 'invalid_state', too_far = 'too_far',
    not_server_entity = 'vehicle_mismatch', plate_mismatch = 'vehicle_mismatch', not_tracked = 'vehicle_mismatch',
    model_mismatch = 'vehicle_mismatch' }

--- Pre-lock: which plate to lock on, or an early error (NPC car / unmarked car). Never uses the plate text as authority.
local function storeTarget(netId)
    netId = math.tointeger(netId)
    local ent = netId and NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) or GetEntityType(ent) ~= 2 then return nil, nil, 'invalid_request' end
    local plate = candidatePlate(ent)
    if plate and Security.IsServerEntity(ent, plate) then return ent, plate end
    -- unmarked: NPC/street car (no row) -> not_owned_vehicle; registered plate on an unmarked entity -> vehicle_mismatch
    local text = Utils.NormalizePlate(GetVehicleNumberPlateText(ent) or '')
    local row = text and Utils.IsValidPlate(text)
        and MySQL.scalar.await('SELECT 1 FROM mdp_vehicles WHERE plate = ? AND state <> ?', { text, VS.REMOVED })
    return nil, nil, row and 'vehicle_mismatch' or 'not_owned_vehicle'
end

--- INSIDE the plate lock, before any side effect: re-read row, then all Security conditions (1)-(5).
local function lockedOwnVehicle(src, ent, plate, evName, allowDriver)
    local row = MySQL.single.await([[SELECT plate, owner, model, state, fuel, mileage,
        UNIX_TIMESTAMP(COALESCE(parked_at, updated_at)) AS mileage_ts FROM mdp_vehicles WHERE plate = ?]], { plate })
    if not row or tonumber(row.state) == VS.REMOVED then return nil, 'not_owned_vehicle' end
    local opts = { plate = plate, row = row, maxDistance = Config.MaxVehicleDistance, allowDriver = allowDriver,
        allowKeys = Config.AllowSharedKeyStore == true }
    local ok, res
    if type(Security.CanStoreOwnVehicle) == 'function' then
        local okC, a, b = pcall(Security.CanStoreOwnVehicle, src, ent, opts)
        if okC then ok, res = a, b else ok, res = false, 'not_server_entity' end
    else
        ok, res = localCanStoreOwnVehicle(src, ent, opts)
    end
    if not ok then
        Security.LogReject(src, evName, tostring(res), { plate = plate })
        return nil, STORE_ERR[res] or 'vehicle_mismatch'
    end
    if res ~= plate then return nil, 'vehicle_mismatch' end
    return row
end

MDP.Callback('mdp_garages:storeVehicle', {
    rateLimit = { max = 1, windowMs = 1000 },
    schema = schemaWith({ netId = Security.Int(1, 65535), garage_id = Security.V.isGarageId, vclass = Security.Optional(Security.Int(0, 22)) }),
    -- no resolvePlate (it reads the plate text) and no requireOwnership (accepts keys): see lockedOwnVehicle
    distance = { getCoords = garageCoords, max = Config.MaxGarageDistance },
}, function(src, data)
    local garage, gerr = Utils.GetGarage(data.garage_id, GARAGE_KINDS)
    if not garage then return { ok = false, error = gerr } end
    local veh, plate, terr = storeTarget(data.netId)
    if not veh then return { ok = false, error = terr } end
    local ped = GetPlayerPed(src)
    if GetVehiclePedIsIn(ped, false) ~= veh then return { ok = false, error = 'not_in_vehicle' } end
    if not Utils.OnlyDriverInside(veh, ped) then return { ok = false, error = 'occupied' } end -- R3b-2
    local res = table.pack(Security.WithLock(plate, src, function()
        local row, err = lockedOwnVehicle(src, veh, plate, 'mdp_garages:storeVehicle', true)
        if not row then return { ok = false, error = err } end
        local vtype = resolveVehicleType(veh, row.model, data.vclass)
        if not Utils.GarageAllowsType(garage, vtype) then return { ok = false, error = 'wrong_vehicle_type' } end
        -- H2: Security.SanitizeProps inside the lock, entity passed as 3rd arg; store its JSON
        local _, propsJson = MDP.Props.Sanitize(data.props, row, veh)
        if data.props ~= nil and not propsJson then
            Security.LogReject(src, 'mdp_garages:storeVehicle', 'invalid_props', { plate = plate })
            return { ok = false, error = 'invalid_props' }
        end
        local fuel = MDP.Props.ResolveFuel(veh, data.fuel, row.fuel)
        local mileage = MDP.Props.ResolveMileage(data.mileage, row.mileage, plate, row.mileage_ts)
        local engine = MDP.Props.Health('engine', GetVehicleEngineHealth(veh)) -- M4
        local body = MDP.Props.Health('body', GetVehicleBodyHealth(veh))
        local affected = MySQL.update.await([[UPDATE mdp_vehicles
            SET state = ?, garage_id = ?, vtype = ?, engine = ?, body = ?, fuel = ?, mileage = ?, props = COALESCE(?, props),
                coords = NULL, parked_at = NULL
            WHERE plate = ? AND state = ?]],
            { VS.GARAGED, data.garage_id, vtype, engine, body, fuel, mileage, propsJson, plate, VS.OUT })
        if affected ~= 1 then return { ok = false, error = 'invalid_state' } end
        Security.UntrackSpawn(plate)
        MDP.Props.ForgetMileage(plate) -- N7: garaged; next spawn stamps again
        MDP.Streamer.Forget(plate)
        DeleteEntity(veh)
        MDP.Props.Hook(Bridge.Keys, 'OnStore', src, plate, VS.GARAGED) -- removes temporary keys per Config.RemoveKeysOnStore
        MDP.Props.Hook(Bridge.FrameworkSync, 'OnStore', plate, data.garage_id, propsJson, fuel, engine, body)
        return { ok = true }
    end))
    if res[1] == false then return { ok = false, error = res[2] or 'locked' } end
    return res[1]
end)

---------------------------------------------------------------------------
-- parkWorld (phase 1): park the vehicle where it stands (state 0 -> 2). The player must have just left it:
-- vehicle empty, player within MaxVehicleDistance. Plate resolved server-side; props/fuel/mileage as storeVehicle.
---------------------------------------------------------------------------
--- Global world limit; AutoImpoundOldest frees the oldest parked car (global limit only). Returns true if room.
local function freeWorldSlot()
    if not Config.AutoImpoundOldest then return false end
    local old = MySQL.single.await('SELECT plate FROM mdp_vehicles WHERE state = ? ORDER BY parked_at ASC LIMIT 1', { VS.PARKED_WORLD })
    if not old then return false end
    return Security.WithLock(old.plate, 0, function()
        local oldEnt = Security.GetSpawnedEntity(old.plate)
        if oldEnt and not Utils.IsVehicleEmpty(oldEnt) then return false end
        local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ? WHERE plate = ? AND state = ?',
            { VS.IMPOUNDED, Config.DefaultImpound, old.plate, VS.PARKED_WORLD })
        if n ~= 1 then return false end
        local reason = (Config.ImpoundReasons or {}).abandoned or { label = 'Abandoned vehicle', fee = 0, hours = 0 }
        local impoundId = MySQL.insert.await([[INSERT INTO mdp_impound (plate, reason, officer, fee, release_after, location)
            VALUES (?, ?, 'system:world_limit', ?, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? HOUR), ?)]],
            { old.plate, reason.label, math.tointeger(reason.fee) or 0, math.tointeger(reason.hours) or 0, Config.DefaultImpound })
        if oldEnt then Security.UntrackSpawn(old.plate); DeleteEntity(oldEnt) end
        MDP.Streamer.Forget(old.plate)
        MDP.Props.Hook(Bridge.FrameworkSync, 'OnImpound', old.plate, impoundId)
        return true
    end) == true
end

MDP.Callback('mdp_garages:parkWorld', {
    rateLimit = { max = 1, windowMs = 1000 },
    schema = schemaWith({ netId = Security.Int(1, 65535), vclass = Security.Optional(Security.Int(0, 22)) }),
    -- owner-only + server mark: pre-check below (before limits/auto-impound) and the full check inside the lock
}, function(src, data)
    local veh, plate, terr = storeTarget(data.netId)
    if not veh then return { ok = false, error = terr } end
    if not Utils.IsVehicleEmpty(veh) then return { ok = false, error = 'occupied' } end
    local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
    if not MDP.Props.ValidCoords(c) then return { ok = false, error = 'invalid_request' } end -- L4
    local owner = MySQL.scalar.await("SELECT owner FROM mdp_vehicles WHERE plate = ? AND state <> ?", { plate, VS.REMOVED })
    if not owner then return { ok = false, error = 'not_owned_vehicle' } end
    if not Security.IsOwner(src, plate, Config.AllowSharedKeyStore == true) then return { ok = false, error = 'not_owner' } end
    local mine = MySQL.scalar.await('SELECT COUNT(*) FROM mdp_vehicles WHERE owner = ? AND state = ?', { owner, VS.PARKED_WORLD }) or 0
    if mine >= (Config.MaxWorldParkedPerPlayer or 5) then
        Bridge.Notify(src, _L('world_limit_player', Config.MaxWorldParkedPerPlayer or 5), 'error')
        return { ok = false, error = 'world_limit' }
    end
    local all = MySQL.scalar.await('SELECT COUNT(*) FROM mdp_vehicles WHERE state = ?', { VS.PARKED_WORLD }) or 0
    if all >= (Config.MaxWorldParkedServer or 150) and not freeWorldSlot() then
        Bridge.Notify(src, _L('world_limit_server'), 'error')
        return { ok = false, error = 'world_limit' }
    end
    local res = table.pack(Security.WithLock(plate, src, function()
        local row, err = lockedOwnVehicle(src, veh, plate, 'mdp_garages:parkWorld', false) -- player is out: distance applies
        if not row then return { ok = false, error = err } end
        local _, propsJson = MDP.Props.Sanitize(data.props, row, veh)
        if data.props ~= nil and not propsJson then return { ok = false, error = 'invalid_props' } end
        local fuel = MDP.Props.ResolveFuel(veh, data.fuel, row.fuel)
        local mileage = MDP.Props.ResolveMileage(data.mileage, row.mileage, plate, row.mileage_ts)
        local engine, body = MDP.Props.Health('engine', GetVehicleEngineHealth(veh)), MDP.Props.Health('body', GetVehicleBodyHealth(veh))
        local n = MySQL.update.await([[UPDATE mdp_vehicles SET state = ?, coords = ?, heading = ?, engine = ?, body = ?, fuel = ?,
            mileage = ?, props = COALESCE(?, props), parked_at = CURRENT_TIMESTAMP WHERE plate = ? AND state = ?]],
            { VS.PARKED_WORLD, json.encode({ x = c.x, y = c.y, z = c.z }), h, engine, body, fuel, mileage, propsJson, plate, VS.OUT })
        if n ~= 1 then return { ok = false, error = 'invalid_state' } end
        SetVehicleDoorsLocked(veh, 2)
        MDP.Props.StampMileage(plate)
        MDP.Streamer.Track(plate) -- the streamer now owns it
        MDP.Props.Hook(Bridge.Keys, 'OnStore', src, plate, VS.PARKED_WORLD) -- keeps temporary keys for state 2
        MDP.Props.Hook(Bridge.FrameworkSync, 'Mirror', plate, { state = VS.PARKED_WORLD, props = propsJson, fuel = fuel, engine = engine, body = body })
        return { ok = true }
    end))
    if res[1] == false then return { ok = false, error = res[2] or 'locked' } end
    return res[1]
end)

---------------------------------------------------------------------------
-- /mdp_regularize <plate> (ace: command.mdp_regularize): fixes pre-a8fda43 / unmarked cars that can no longer be stored.
-- Deletes every EMPTY unmarked entity carrying that plate and puts the row in GARAGED at its last garage
-- (or Config.DefaultGarage). Occupied entities are left alone and the command refuses. Logged.
---------------------------------------------------------------------------
RegisterCommand('mdp_regularize', function(src, args)
    local function reply(msg) if src == 0 then print('[mdp_garages] ' .. msg) else Bridge.Notify(src, msg, 'inform') end end
    local plate = Utils.NormalizePlate(table.concat(args or {}, ' '))
    if not plate or not Utils.IsValidPlate(plate) then return reply('usage: mdp_regularize <plate>') end
    Security.WithLock(plate, src, function()
        local row = MySQL.single.await('SELECT garage_id, state FROM mdp_vehicles WHERE plate = ? AND state <> ?', { plate, VS.REMOVED })
        if not row then return reply(('no vehicle %s'):format(plate)) end
        local tracked = Security.GetSpawnedEntity(plate)
        local deleted = 0
        for _, ent in ipairs(GetAllVehicles()) do
            if Utils.NormalizePlate(GetVehicleNumberPlateText(ent) or '') == plate and not Security.IsServerEntity(ent, plate) then
                if not Utils.IsVehicleEmpty(ent) then return reply(('%s: an unmarked entity is occupied, try again when empty'):format(plate)) end
                if ent == tracked then Security.UntrackSpawn(plate) end
                DeleteEntity(ent); deleted = deleted + 1
            end
        end
        if Security.GetSpawnedEntity(plate) then return reply(('%s: a marked entity is still out; store it normally'):format(plate)) end
        local gid = Utils.ResolveGarageId and Utils.ResolveGarageId(row.garage_id, plate) or row.garage_id
        if type(gid) ~= 'string' or gid == '' or gid:sub(1, 7) == 'impound' then gid = Config.DefaultGarage end
        MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ?, coords = NULL, parked_at = NULL WHERE plate = ? AND state <> ?',
            { VS.GARAGED, gid, plate, VS.REMOVED })
        MDP.Streamer.Forget(plate)
        MDP.Props.Hook(Bridge.FrameworkSync, 'OnStore', plate, gid)
        print(('[mdp_garages] mdp_regularize by %s: %s -> GARAGED in %s (%d unmarked entities deleted, previous state %s)')
            :format(src == 0 and 'console' or tostring(src), plate, gid, deleted, tostring(row.state)))
        reply(('%s regularized -> %s'):format(plate, gid))
    end)
end, true) -- restricted: add_ace group.admin command.mdp_regularize allow

---------------------------------------------------------------------------
-- Server export for dealerships: exports.mdp_garages:SpawnOwnedVehicle(plate, coords, src) -> netId | nil, err
-- Same flow as takeOut: lock, re-read row, owner == src identifier, state GARAGED or OUT without tracked entity,
-- MDP.Props.SpawnVehicle (server mark, TrackSpawn, props via RequestApply, fuel), state OUT, keys, FrameworkSync.
-- Errors: invalid_plate, invalid_coords, invalid_source, rate_limited, not_ready, not_owned_vehicle, not_owner,
-- invalid_state, already_out, spawn_failed, locked.
---------------------------------------------------------------------------
local function parseCoords(c)
    if c == nil then return nil end
    local ok, x, y, z, w = pcall(function() return c.x, c.y, c.z, c.w end)
    if not ok then return nil end
    x, y, z, w = tonumber(x), tonumber(y), tonumber(z), tonumber(w) or 0.0
    if not x or not y or not z or w ~= w or w == math.huge or w == -math.huge then return nil end
    local v = vec3(x + 0.0, y + 0.0, z + 0.0)
    if not MDP.Props.ValidCoords(v) then return nil end -- L4: finite, inside the map
    return v, w + 0.0
end

local function SpawnOwnedVehicle(plate, coords, src)
    if not MDP.Ready then return nil, 'not_ready' end
    plate = type(plate) == 'string' and Utils.NormalizePlate(plate) or nil
    if not plate or not Utils.IsValidPlate(plate) then return nil, 'invalid_plate' end
    local pos, heading = parseCoords(coords)
    if not pos then return nil, 'invalid_coords' end
    src = math.tointeger(tonumber(src))
    if not src or src <= 0 or not GetPlayerName(src) then return nil, 'invalid_source' end -- online player only
    if Security.RateLimit and not Security.RateLimit(src, 'export:SpawnOwnedVehicle', 3, 10000) then return nil, 'rate_limited' end
    local ident = Bridge.GetIdentifier(src)
    if not ident then return nil, 'invalid_source' end
    print(('[mdp_garages] SpawnOwnedVehicle %s for src %d by %s'):format(plate, src, tostring(GetInvokingResource())))
    local res = table.pack(Security.WithLock(plate, src, function()
        local row = MySQL.single.await([[SELECT plate, owner, model, vtype, props, state, garage_id, fuel, engine, body, mileage
            FROM mdp_vehicles WHERE plate = ?]], { plate })
        if not row or tonumber(row.state) == VS.REMOVED then return nil, 'not_owned_vehicle' end
        if row.owner ~= ident then return nil, 'not_owner' end
        local state = tonumber(row.state)
        if state ~= VS.GARAGED and state ~= VS.OUT then return nil, 'invalid_state' end
        if Security.GetSpawnedEntity(plate) then return nil, 'already_out' end
        if state == VS.GARAGED then
            local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, parked_at = NULL WHERE plate = ? AND state = ?',
                { VS.OUT, plate, VS.GARAGED })
            if n ~= 1 then return nil, 'invalid_state' end
        end
        local veh, netId = MDP.Props.SpawnVehicle(row, pos.x, pos.y, pos.z, heading, src) -- pcall + entity cleanup inside (H1/N3)
        if not veh then
            if state == VS.GARAGED then -- roll back to the exact previous state
                MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ? WHERE plate = ? AND state = ?',
                    { VS.GARAGED, row.garage_id, plate, VS.OUT })
            end
            return nil, 'spawn_failed'
        end
        MDP.Props.GiveKeys(src, veh, plate) -- after the entity exists
        MDP.Props.Hook(Bridge.FrameworkSync, 'OnSpawn', plate)
        return netId
    end))
    if res[1] == false then return nil, res[2] or 'locked' end -- lock not acquired
    return res[1], res[2]
end
exports('SpawnOwnedVehicle', SpawnOwnedVehicle)
