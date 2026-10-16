-- Phase 1: vehicle props persistence + shared server spawn (takeOut and parked streamer).
-- Props validation is owned by Security (Security.SanitizeProps); this file only wraps it with a minimal fallback.
MDP.Props = {}
local VS = Constants.VehicleState
local MAX_PROPS_JSON = 16 * 1024

--- Sanitize client props for a vehicle row. Returns cleanProps|nil, err.
--- dbRow: { plate, model, mileage, fuel, ... } ; entityModel: GetEntityModel(veh) (server-read)
function MDP.Props.Sanitize(props, dbRow, entityModel)
    if props == nil then return nil, nil end -- props are optional; keep DB props
    if type(props) ~= 'table' then return nil, 'invalid_props' end
    if Security.SanitizeProps then
        local row = {}
        for k, v in pairs(dbRow) do row[k] = v end
        row.entityModel = entityModel
        local ok, clean, err = pcall(Security.SanitizeProps, props, row)
        if not ok then return nil, 'invalid_props' end
        if not clean then return nil, err or 'invalid_props' end
        return clean
    end
    -- TODO(security): minimal fallback until Security.SanitizeProps lands (no field whitelist here on purpose).
    local okE, encoded = pcall(json.encode, props)
    if not okE or #encoded > MAX_PROPS_JSON then return nil, 'invalid_props' end
    if props.model ~= nil and Utils.ModelHash(props.model) ~= entityModel then return nil, 'invalid_props' end
    props.plate = dbRow.plate -- server plate always wins
    return props
end

local function fuelServerCapable()
    return Bridge.Fuel and type(Bridge.Fuel.ServerCapable) == 'function' and Bridge.Fuel.ServerCapable() == true
end
MDP.Props.FuelServerCapable = fuelServerCapable

--- Fuel to persist on store: server adapter if capable (ox_fuel), else client value clamped 0-100 and
--- never above last DB value + 2 (anti refuel-by-store).
function MDP.Props.ResolveFuel(veh, clientFuel, dbFuel)
    dbFuel = tonumber(dbFuel) or 100
    if fuelServerCapable() and Bridge.Fuel.GetFuel then
        local ok, f = pcall(Bridge.Fuel.GetFuel, veh)
        if ok and tonumber(f) then return math.max(0, math.min(100, tonumber(f))) end
    end
    local f = tonumber(clientFuel)
    if not f or f ~= f then return dbFuel end
    return math.max(0, math.min(100, f, dbFuel + 2))
end

--- Mileage (km) never decreases; per-store increase capped by Config.MaxMileageDeltaKm.
function MDP.Props.ResolveMileage(clientKm, dbKm)
    dbKm = tonumber(dbKm) or 0
    local v = tonumber(clientKm)
    if not v or v ~= v or v < dbKm then return dbKm end
    return math.min(v, dbKm + (Config.MaxMileageDeltaKm or 300))
end

--- Decode DB props JSON safely.
function MDP.Props.Decode(raw)
    if type(raw) ~= 'string' or raw == '' then return nil end
    local ok, t = pcall(json.decode, raw)
    return (ok and type(t) == 'table') and t or nil
end

--- Server spawn used by takeOut and the parked streamer. Caller holds the plate lock and has
--- already checked GetSpawnedEntity(plate) == nil. Returns veh, netId | nil, 'spawn_failed'.
--- row: { plate, model, vtype, props (json), fuel, engine, body }
function MDP.Props.SpawnVehicle(row, x, y, z, heading, ownerSrc)
    local vtype = Utils.IsValidVehicleType(row.vtype) and row.vtype or 'automobile'
    local veh = CreateVehicleServerSetter(Utils.ModelHash(row.model), vtype, x, y, z, heading or 0.0)
    local t = GetGameTimer() + 3000
    while (not veh or veh == 0 or not DoesEntityExist(veh)) and GetGameTimer() < t do Wait(50) end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil, 'spawn_failed' end
    SetVehicleNumberPlateText(veh, row.plate)
    local fuel = tonumber(row.fuel) or 100
    local bag = Entity(veh).state
    bag:set('mdp_plate', row.plate, true)
    -- client applier (entity owner) applies props + health (+ fuel when the fuel resource is client-side)
    bag:set('mdp_props', {
        props = MDP.Props.Decode(row.props),
        engine = tonumber(row.engine) or 1000.0,
        body = tonumber(row.body) or 1000.0,
        fuel = fuel,
        mileage = tonumber(row.mileage) or 0.0, -- km; client odometer base
        fuelOnClient = not fuelServerCapable(),
    }, true)
    if fuelServerCapable() and Bridge.Fuel.SetFuel then pcall(Bridge.Fuel.SetFuel, veh, fuel) end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    Security.TrackSpawn(row.plate, netId, ownerSrc)
    return veh, netId
end

--- Give keys AFTER the entity exists (qbx_vehiclekeys needs the entity). Never throws.
function MDP.Props.GiveKeys(src, veh, plate)
    if not (Bridge.Keys and type(Bridge.Keys.GiveKeys) == 'function') then return false end
    local ok, res = pcall(Bridge.Keys.GiveKeys, src, veh or plate)
    if not ok or res == false then
        print(('^3[mdp_garages] GiveKeys failed for %s (src %s)^0'):format(tostring(plate), tostring(src)))
        return false
    end
    return true
end

local _ = VS
