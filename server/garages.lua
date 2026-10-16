-- Garage callbacks used by the NUI (client proxies them 1:1). Responses: { ok, error?, data? }.
local VS = Constants.VehicleState
local GARAGE_KINDS = { public = true, private = true }

local function garageCoords(_, data)
    local g = Utils.GetGarage(data and data.garage_id, GARAGE_KINDS)
    return g and g.coords or nil
end

--- Vehicles the player owns or holds keys for, shaped per the NUI contract.
local function listVehicles(src)
    local ident = Bridge.GetIdentifier(src)
    if not ident then return nil end
    local rows = MySQL.query.await([[
        SELECT v.plate, v.owner, v.model, v.coords, v.state, v.fuel, v.engine, v.body, v.mileage, v.garage_id
        FROM mdp_vehicles v
        WHERE v.owner = ? OR v.plate IN (SELECT k.plate FROM mdp_vehicle_keys k WHERE k.holder = ?)]], { ident, ident }) or {}
    local out = {}
    for _, r in ipairs(rows) do
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
        out[#out + 1] = v
    end
    return out
end

Security.RegisterSecureCallback('mdp_garages:getVehicles', {
    rateLimit = { max = 5, windowMs = 10000 },
    schema = { garage_id = Security.V.isGarageId },
    distance = { getCoords = garageCoords, max = Config.MaxGarageDistance },
}, function(src, data)
    local _, err = Utils.GetGarage(data.garage_id, GARAGE_KINDS)
    if err then return { ok = false, error = err } end
    local list = listVehicles(src)
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
    local n = MySQL.scalar.await('SELECT COUNT(*) FROM mdp_fines WHERE owner = ? AND paid = ?', { Bridge.GetIdentifier(src), Constants.FineStatus.UNPAID })
    return (tonumber(n) or 0) >= (Config.UnpaidFinesThreshold or 1)
end

Security.RegisterSecureCallback('mdp_garages:takeOut', {
    rateLimit = { max = 1, windowMs = 1000 },
    schema = { plate = 'plate', garage_id = Security.V.isGarageId },
    requireOwnership = true, -- owner or key holder
    distance = { getCoords = garageCoords, max = Config.MaxGarageDistance },
}, function(src, data)
    local garage, gerr = Utils.GetGarage(data.garage_id, GARAGE_KINDS)
    if not garage then return { ok = false, error = gerr } end
    local plate = data.plate -- already normalized by ValidateSchema
    local row = MySQL.single.await('SELECT model, props, state, garage_id FROM mdp_vehicles WHERE plate = ?', { plate })
    if not row then return { ok = false, error = 'not_found' } end
    if tonumber(row.state) == VS.RETIRED then return { ok = false, error = 'retired' } end
    if tonumber(row.state) ~= VS.GARAGED then return { ok = false, error = 'already_out' } end
    if row.garage_id ~= data.garage_id then return { ok = false, error = 'wrong_garage' } end
    if unpaidFinesBlocked(src) then return { ok = false, error = 'unpaid_fines' } end

    local res = table.pack(Security.WithLock(plate, src, function()
        if Security.GetSpawnedEntity(plate) then return { ok = false, error = 'already_out' } end
        local spawn
        for _, s in ipairs(garage.spawns or {}) do if isSpawnFree(s) then spawn = s break end end
        if not spawn then return { ok = false, error = 'no_spawn' } end
        local affected = MySQL.update.await(
            'UPDATE mdp_vehicles SET state = ?, parked_at = NULL WHERE plate = ? AND state = ? AND garage_id = ?',
            { VS.OUT, plate, VS.GARAGED, data.garage_id })
        if affected ~= 1 then return { ok = false, error = 'already_out' } end
        -- vehicle type: 'automobile' for phase 0 (bikes/boats/heli need per-model type, phase 1)
        local veh = CreateVehicleServerSetter(joaat(row.model), 'automobile', spawn.x, spawn.y, spawn.z, spawn.w)
        local t = GetGameTimer() + 3000
        while (not veh or veh == 0 or not DoesEntityExist(veh)) and GetGameTimer() < t do Wait(50) end
        if not veh or veh == 0 or not DoesEntityExist(veh) then
            MySQL.update.await('UPDATE mdp_vehicles SET state = ? WHERE plate = ? AND state = ?', { VS.GARAGED, plate, VS.OUT })
            return { ok = false, error = 'spawn_failed' }
        end
        SetVehicleNumberPlateText(veh, plate)
        local ent = Entity(veh).state
        ent:set('mdp_plate', plate, true)
        if row.props then ent:set('mdp_props', row.props, true) end -- client applies props (phase 1)
        local netId = NetworkGetNetworkIdFromEntity(veh)
        Security.TrackSpawn(plate, netId, src)
        return { ok = true, data = { netId = netId } }
    end))
    local r = res[1]
    if r == false then return { ok = false, error = res[2] or 'locked' } end
    return r
end)
