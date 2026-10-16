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

local function unpaidFinesBlocked(src)
    if not Config.BlockOnUnpaidFines then return false end
    -- only real unpaid fines: needs_review (possibly already paid via invoice) does not count (QA N8)
    local n = MySQL.scalar.await("SELECT COUNT(*) FROM mdp_fines WHERE owner = ? AND paid = ? AND channel IN ('internal', 'invoice')",
        { Bridge.GetIdentifier(src), Constants.FineStatus.UNPAID })
    return (tonumber(n) or 0) >= (Config.UnpaidFinesThreshold or 1)
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
    local row = MySQL.single.await('SELECT plate, model, vtype, props, state, garage_id, coords, fuel, engine, body, mileage FROM mdp_vehicles WHERE plate = ?', { plate })
    if not row or tonumber(row.state) == VS.REMOVED then return { ok = false, error = 'not_found' } end
    if tonumber(row.state) == VS.RETIRED then return { ok = false, error = 'retired' } end
    local state = tonumber(row.state)
    -- Kept in phase 1 as a feature ('bring my car'): PARKED_WORLD can be taken out from any garage (the streamer only
    -- spawns it where it was parked; it does not move it to a garage)
    if state == VS.IMPOUNDED then return { ok = false, error = 'impounded' } end -- paid release: phase 5
    if state ~= VS.GARAGED and state ~= VS.PARKED_WORLD then return { ok = false, error = 'already_out' } end
    if state == VS.GARAGED and row.garage_id ~= data.garage_id then return { ok = false, error = 'wrong_garage' } end
    local vtype = Utils.IsValidVehicleType(row.vtype) and row.vtype or 'automobile'
    if not Utils.GarageAllowsType(garage, vtype) then return { ok = false, error = 'wrong_vehicle_type' } end
    if unpaidFinesBlocked(src) then return { ok = false, error = 'unpaid_fines' } end

    local res = table.pack(Security.WithLock(plate, src, function()
        local tracked = Security.GetSpawnedEntity(plate)
        if tracked then
            if state ~= VS.PARKED_WORLD then return { ok = false, error = 'already_out' } end
            -- R3-4: never delete a world vehicle someone is using or has moved
            for seat = -1, (GetVehicleMaxNumberOfPassengers and GetVehicleMaxNumberOfPassengers(tracked) or 6) - 1 do
                local ped = GetPedInVehicleSeat(tracked, seat)
                if ped and ped ~= 0 then return { ok = false, error = 'in_use' } end
            end
            if row.coords then
                local okC, c = pcall(json.decode, row.coords)
                if okC and type(c) == 'table' and c.x then
                    local cur = GetEntityCoords(tracked)
                    if #(cur - vec3(c.x, c.y, c.z)) > (Config.ParkedMoveTolerance or 5.0) then
                        return { ok = false, error = 'vehicle_moved' }
                    end
                end
            end
            -- world-parked entity still alive: remove it first so only one exists
            Security.UntrackSpawn(plate)
            DeleteEntity(tracked)
            MDP.Streamer.Forget(plate)
        end
        local spawn
        for _, s in ipairs(garage.spawns or {}) do if isSpawnFree(s) then spawn = s break end end
        if not spawn then return { ok = false, error = 'no_spawn' } end
        -- conditional transition on the state we read (1 in this garage, or 2), affectedRows checked
        local affected
        if state == VS.GARAGED then
            affected = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, parked_at = NULL WHERE plate = ? AND state = ? AND garage_id = ?',
                { VS.OUT, plate, VS.GARAGED, data.garage_id })
        else
            affected = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, parked_at = NULL, coords = NULL WHERE plate = ? AND state = ?',
                { VS.OUT, plate, VS.PARKED_WORLD })
        end
        if affected ~= 1 then return { ok = false, error = 'already_out' } end
        row.vtype = vtype
        local veh, netId = MDP.Props.SpawnVehicle(row, spawn.x, spawn.y, spawn.z, spawn.w, src)
        if not veh then
            MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ? WHERE plate = ? AND state = ?',
                { VS.GARAGED, data.garage_id, plate, VS.OUT })
            return { ok = false, error = 'spawn_failed' }
        end
        MDP.Streamer.Forget(plate)
        MDP.Props.GiveKeys(src, veh, plate) -- after the entity exists
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

MDP.Callback('mdp_garages:storeVehicle', {
    rateLimit = { max = 1, windowMs = 1000 },
    schema = {
        netId = Security.Int(1, 65535), garage_id = Security.V.isGarageId, vclass = Security.Optional(Security.Int(0, 22)),
        props = Security.Optional(function(v) return type(v) == 'table' end), -- lib.getVehicleProperties (sanitized below)
        fuel = Security.Optional(function(v) return type(v) == 'number' and v == v end),
        mileage = Security.Optional(function(v) return type(v) == 'number' and v == v and v >= 0 end), -- km
    },
    resolvePlate = MDP.Vehicles.ResolvePlateFromNetId, -- server-side plate -> data._plate
    requireOwnership = true,              -- owner or key holder, checked on data._plate
    distance = { getCoords = garageCoords, max = Config.MaxGarageDistance },
}, function(src, data)
    local garage, gerr = Utils.GetGarage(data.garage_id, GARAGE_KINDS)
    if not garage then return { ok = false, error = gerr } end
    local plate = data._plate
    local _, _, veh = Security.PlateFromNetId(data.netId)
    if not veh then return { ok = false, error = 'invalid_request' } end
    if not Security.IsNear(src, GetEntityCoords(veh), Config.MaxVehicleDistance) then return { ok = false, error = 'too_far' } end
    local row = MySQL.single.await('SELECT plate, model, state, fuel, mileage FROM mdp_vehicles WHERE plate = ?', { plate })
    if not row then return { ok = false, error = 'not_owner' } end
    if tonumber(row.state) == VS.REMOVED then return { ok = false, error = 'not_found' } end
    if GetEntityModel(veh) ~= Utils.ModelHash(row.model) then return { ok = false, error = 'invalid_request' } end
    -- QA N13: player must be in the vehicle, and it must be OUR tracked entity (anti-clone)
    local ped = GetPlayerPed(src)
    if GetVehiclePedIsIn(ped, false) ~= veh then return { ok = false, error = 'not_in_vehicle' } end
    -- R3b-2: the storing player must be the driver and alone (never delete an entity with others inside)
    if not Utils.OnlyDriverInside(veh, ped) then return { ok = false, error = 'occupied' } end
    local tracked = Security.GetSpawnedEntity(plate)
    if tracked and tracked ~= veh then
        -- another tracked entity has this plate: this one is a clone
        Security.LogReject(src, 'mdp_garages:storeVehicle', 'clone_detected', { plate = plate })
        DeleteEntity(veh) -- the clone; the tracked original stays
        return { ok = false, error = 'clone_detected' }
    end
    if not tracked then
        -- R3-1: not spawned by us (dealership, other script). Accept if DB ownership (requireOwnership above),
        -- model hash (checked above) and state OUT match; then track it.
        if tonumber(row.state) ~= VS.OUT then return { ok = false, error = 'not_tracked' } end
        Security.TrackSpawn(plate, math.tointeger(data.netId), src)
        Entity(veh).state:set('mdp_plate', plate, true)
    end
    local vtype = resolveVehicleType(veh, row.model, data.vclass)
    if not Utils.GarageAllowsType(garage, vtype) then return { ok = false, error = 'wrong_vehicle_type' } end
    -- phase 1: props (Security.SanitizeProps), fuel (server adapter or clamped client value), mileage (never decreases)
    local props, perr = MDP.Props.Sanitize(data.props, row, GetEntityModel(veh))
    if perr then return { ok = false, error = 'invalid_props' } end
    local fuel = MDP.Props.ResolveFuel(veh, data.fuel, row.fuel)
    local mileage = MDP.Props.ResolveMileage(data.mileage, row.mileage)
    local propsJson = props and json.encode(props) or nil
    local res = table.pack(Security.WithLock(plate, src, function()
        local affected = MySQL.update.await([[UPDATE mdp_vehicles
            SET state = ?, garage_id = ?, vtype = ?, engine = ?, body = ?, fuel = ?, mileage = ?, props = COALESCE(?, props),
                coords = NULL, parked_at = NULL
            WHERE plate = ? AND state IN (?, ?)]],
            { VS.GARAGED, data.garage_id, vtype, GetVehicleEngineHealth(veh), GetVehicleBodyHealth(veh), fuel, mileage, propsJson,
              plate, VS.OUT, VS.PARKED_WORLD })
        if affected ~= 1 then return { ok = false, error = 'invalid_state' } end
        Security.UntrackSpawn(plate)
        MDP.Streamer.Forget(plate)
        DeleteEntity(veh)
        return { ok = true }
    end))
    if res[1] == false then return { ok = false, error = res[2] or 'locked' } end
    return res[1]
end)

---------------------------------------------------------------------------
-- parkWorld (phase 1): park the vehicle where it stands (state 0 -> 2). The player must have just left it:
-- vehicle empty, player within MaxVehicleDistance. Plate resolved server-side; props/fuel/mileage as storeVehicle.
---------------------------------------------------------------------------
MDP.Callback('mdp_garages:parkWorld', {
    rateLimit = { max = 1, windowMs = 1000 },
    schema = {
        netId = Security.Int(1, 65535), vclass = Security.Optional(Security.Int(0, 22)),
        props = Security.Optional(function(v) return type(v) == 'table' end),
        fuel = Security.Optional(function(v) return type(v) == 'number' and v == v end),
        mileage = Security.Optional(function(v) return type(v) == 'number' and v == v and v >= 0 end),
    },
    resolvePlate = MDP.Vehicles.ResolvePlateFromNetId,
    requireOwnership = true,
}, function(src, data)
    local plate = data._plate
    local _, _, veh = Security.PlateFromNetId(data.netId)
    if not veh then return { ok = false, error = 'invalid_request' } end
    if not Security.IsNear(src, GetEntityCoords(veh), Config.MaxVehicleDistance) then return { ok = false, error = 'too_far' } end
    if not Utils.IsVehicleEmpty(veh) then return { ok = false, error = 'occupied' } end
    local row = MySQL.single.await('SELECT plate, owner, model, state, fuel, mileage FROM mdp_vehicles WHERE plate = ?', { plate })
    if not row or tonumber(row.state) == VS.REMOVED then return { ok = false, error = 'not_found' } end
    if tonumber(row.state) ~= VS.OUT then return { ok = false, error = 'invalid_state' } end
    if GetEntityModel(veh) ~= Utils.ModelHash(row.model) then return { ok = false, error = 'invalid_request' } end
    local tracked = Security.GetSpawnedEntity(plate)
    if tracked and tracked ~= veh then
        Security.LogReject(src, 'mdp_garages:parkWorld', 'clone_detected', { plate = plate })
        DeleteEntity(veh)
        return { ok = false, error = 'clone_detected' }
    end
    -- limits (owner of the vehicle, then server-wide)
    local mine = MySQL.scalar.await('SELECT COUNT(*) FROM mdp_vehicles WHERE owner = ? AND state = ?', { row.owner, VS.PARKED_WORLD }) or 0
    if mine >= (Config.MaxWorldParkedPerPlayer or 5) then
        Bridge.Notify(src, _L('world_limit_player', Config.MaxWorldParkedPerPlayer or 5), 'error')
        return { ok = false, error = 'world_limit' }
    end
    local all = MySQL.scalar.await('SELECT COUNT(*) FROM mdp_vehicles WHERE state = ?', { VS.PARKED_WORLD }) or 0
    if all >= (Config.MaxWorldParkedServer or 150) then
        local freed = false
        if Config.AutoImpoundOldest then
            local old = MySQL.single.await('SELECT plate FROM mdp_vehicles WHERE state = ? ORDER BY parked_at ASC LIMIT 1', { VS.PARKED_WORLD })
            if old then
                freed = Security.WithLock(old.plate, 0, function()
                    local oldEnt = Security.GetSpawnedEntity(old.plate)
                    if oldEnt and not Utils.IsVehicleEmpty(oldEnt) then return false end
                    local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ? WHERE plate = ? AND state = ?',
                        { VS.IMPOUNDED, Config.DefaultImpound, old.plate, VS.PARKED_WORLD })
                    if n ~= 1 then return false end
                    local reason = (Config.ImpoundReasons or {}).abandoned or { label = 'Abandoned vehicle', fee = 0, hours = 0 }
                    MySQL.insert.await([[INSERT INTO mdp_impound (plate, reason, officer, fee, release_after, location)
                        VALUES (?, ?, 'system:world_limit', ?, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? HOUR), ?)]],
                        { old.plate, reason.label, math.tointeger(reason.fee) or 0, math.tointeger(reason.hours) or 0, Config.DefaultImpound })
                    if oldEnt then Security.UntrackSpawn(old.plate); DeleteEntity(oldEnt) end
                    MDP.Streamer.Forget(old.plate)
                    return true
                end) == true
            end
        end
        if not freed then
            Bridge.Notify(src, _L('world_limit_server'), 'error')
            return { ok = false, error = 'world_limit' }
        end
    end
    local props, perr = MDP.Props.Sanitize(data.props, row, GetEntityModel(veh))
    if perr then return { ok = false, error = 'invalid_props' } end
    local fuel = MDP.Props.ResolveFuel(veh, data.fuel, row.fuel)
    local mileage = MDP.Props.ResolveMileage(data.mileage, row.mileage)
    local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
    local res = table.pack(Security.WithLock(plate, src, function()
        local n = MySQL.update.await([[UPDATE mdp_vehicles SET state = ?, coords = ?, heading = ?, engine = ?, body = ?, fuel = ?,
            mileage = ?, props = COALESCE(?, props), parked_at = CURRENT_TIMESTAMP WHERE plate = ? AND state = ?]],
            { VS.PARKED_WORLD, json.encode({ x = c.x, y = c.y, z = c.z }), h, GetVehicleEngineHealth(veh), GetVehicleBodyHealth(veh),
              fuel, mileage, props and json.encode(props) or nil, plate, VS.OUT })
        if n ~= 1 then return { ok = false, error = 'invalid_state' } end
        if not tracked then
            Security.TrackSpawn(plate, math.tointeger(data.netId), src)
            Entity(veh).state:set('mdp_plate', plate, true)
        end
        SetVehicleDoorsLocked(veh, 2)
        MDP.Streamer.Track(plate) -- the streamer now owns it (despawns when nobody is near)
        return { ok = true }
    end))
    if res[1] == false then return { ok = false, error = res[2] or 'locked' } end
    return res[1]
end)
