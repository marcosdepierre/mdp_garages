-- Phase 1: vehicle props persistence + shared server spawn (takeOut and parked streamer).
-- Props validation authority: Security.SanitizeProps(props, dbRow, entity) -> clean, nil, json | nil, err.
MDP.Props = {}
local MAX_PROPS_JSON = 16 * 1024 -- DB props above this are never replicated

local function clampFuel(v)
    if Bridge.FuelCommon and Bridge.FuelCommon.Clamp then return Bridge.FuelCommon.Clamp(v) end
    v = tonumber(v) or 100.0; if v ~= v then v = 100.0 end
    return math.max(0.0, math.min(100.0, v))
end

--- Health clamp for every save (M4). kind = 'engine' | 'body'.
--- Single range authority: Security.ClampHealth (engine -4000..1000, body 0..1000).
function MDP.Props.Health(kind, v) return Security.ClampHealth(kind, v) end

--- L4: coords from an entity are only stored if finite and inside the map.
function MDP.Props.ValidCoords(c)
    if not c then return false end
    for _, v in ipairs({ c.x, c.y, c.z }) do
        if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return false end
    end
    return math.abs(c.x) <= 10000 and math.abs(c.y) <= 10000 and c.z > -200 and c.z < 3000
end

--- Sanitize client props. Returns clean, json | nil, err | nil, nil (no props sent: keep DB props).
--- dbRow must contain plate, model, mileage. Call INSIDE the plate lock (H2).
function MDP.Props.Sanitize(props, dbRow, veh)
    if props == nil then return nil, nil end
    if type(props) ~= 'table' then return nil, 'props_not_table' end
    -- N8: no permissive fallback; without Security.SanitizeProps nothing is saved
    if type(Security.SanitizeProps) ~= 'function' then return nil, 'sanitizer_missing' end
    local ok, clean, err, encoded = pcall(Security.SanitizeProps, props, dbRow, veh, MDP.Props.ElapsedSec(dbRow.plate, dbRow.mileage_ts))
    if not ok then return nil, 'sanitize_error' end
    if not clean then return nil, err or 'invalid_props' end
    return clean, encoded or json.encode(clean)
end

function MDP.Props.FuelServerCapable()
    return Bridge.Fuel and type(Bridge.Fuel.ServerCapable) == 'function' and Bridge.Fuel.ServerCapable() == true
end

--- Fuel to persist: server state bag when capable (ox_fuel), else client value clamped 0-100 and <= DB + 2.
function MDP.Props.ResolveFuel(veh, clientFuel, dbFuel)
    dbFuel = tonumber(dbFuel) or 100
    if MDP.Props.FuelServerCapable() then
        local f = tonumber(Entity(veh).state.fuel)
        if f then return clampFuel(f) end
    end
    local f = tonumber(clientFuel)
    if not f or f ~= f then return dbFuel end
    return math.min(clampFuel(f), dbFuel + 2)
end

--- Time base for the km cap: last mileage update per plate (set on spawn/takeOut/streamer spawn, store, park).
local mileageStamp = {}
function MDP.Props.StampMileage(plate) if plate then mileageStamp[plate] = os.time() end end
function MDP.Props.ForgetMileage(plate) if plate then mileageStamp[plate] = nil end end
--- Seconds since the last mileage time base. N5: falls back to the DB time (UNIX_TIMESTAMP(COALESCE(parked_at,
--- updated_at)) selected as mileage_ts) when we never stamped the plate (dealership cars, after a restart).
function MDP.Props.ElapsedSec(plate, dbTs)
    local base = plate and mileageStamp[plate] or tonumber(dbTs)
    return base and math.max(0, os.time() - math.floor(base)) or 0
end
--- N7: drop stamps older than 24 h (periodic sweep).
CreateThread(function()
    while true do
        Wait(10 * 60000)
        local cutoff = os.time() - 86400
        for plate, t in pairs(mileageStamp) do if t < cutoff then mileageStamp[plate] = nil end end
    end
end)

--- N6: unpredictable single-use token (several randoms mixed with timers and a counter).
local tokenSeq = 0
function MDP.Props.NewToken()
    tokenSeq = tokenSeq + 1
    local a, b, c = math.random(0, 0x7FFFFFFF), math.random(0, 0x7FFFFFFF), math.random(0, 0x7FFFFFFF)
    return ('%08x%08x%08x%06x'):format(a ~ GetGameTimer(), b ~ os.time(), c ~ (tokenSeq * 2654435761 & 0x7FFFFFFF), tokenSeq & 0xFFFFFF)
end

--- Mileage (km): Security.ClampMileage(plate, oldKm, newKm, elapsedSec) is the authority (never decreases, time cap).
function MDP.Props.ResolveMileage(clientKm, dbKm, plate, dbTs)
    dbKm = tonumber(dbKm) or 0
    local v = tonumber(clientKm)
    if not v or v ~= v or v < dbKm then return dbKm end
    local km = Security.ClampMileage(plate, dbKm, v, MDP.Props.ElapsedSec(plate, dbTs))
    return math.max(dbKm, tonumber(km) or dbKm)
end

--- DB props JSON -> table (L2: oversized blobs are ignored, never replicated).
function MDP.Props.Decode(raw)
    if type(raw) ~= 'string' or raw == '' or #raw > MAX_PROPS_JSON then return nil end
    local ok, t = pcall(json.decode, raw)
    return (ok and type(t) == 'table') and t or nil
end

--- Hand props to the entity owner: Integrations' Bridge.Props.RequestApply (confirm/timeout), else 'mdp:props' bag.
function MDP.Props.RequestApply(veh, payload, src)
    if Bridge.Props and type(Bridge.Props.RequestApply) == 'function' then
        local ok, armed = pcall(Bridge.Props.RequestApply, veh, payload, src)
        if ok and armed ~= false then return end
        print('^3[mdp_garages] Bridge.Props.RequestApply failed: ' .. tostring(armed) .. ' (state bag fallback)^0')
    end
    Entity(veh).state:set('mdp:props', json.encode(payload), true)
end

local function doSpawn(holder, row, x, y, z, heading, ownerSrc)
    local vtype = Utils.IsValidVehicleType(row.vtype) and row.vtype or 'automobile'
    local veh = CreateVehicleServerSetter(Utils.ModelHash(row.model), vtype, x + 0.0, y + 0.0, z + 0.0, (heading or 0.0) + 0.0)
    holder.veh = veh -- N3: keep the handle so a later error can delete it
    local t = GetGameTimer() + 3000
    while (not veh or veh == 0 or not DoesEntityExist(veh)) and GetGameTimer() < t do Wait(50) end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    Security.MarkServerEntity(veh, row.plate) -- N1/N10: server-side proof of origin, right after the entity exists
    SetVehicleNumberPlateText(veh, row.plate)
    -- payload envelope agreed with Integrations (bridge/vehicle/props.lua): props from DB, fuel/health from DB columns
    local props = MDP.Props.Decode(row.props)
    if props then props.plate = row.plate end
    local fuel = clampFuel(row.fuel)
    local bag = Entity(veh).state
    bag:set('mdp_plate', row.plate, true)
    bag:set('mdp:mileage', tonumber(row.mileage) or 0.0, true) -- km, odometer base for the driver
    if MDP.Props.FuelServerCapable() then bag:set('fuel', fuel, true) end
    MDP.Props.RequestApply(veh, {
        props = props, engine = MDP.Props.Health('engine', row.engine), body = MDP.Props.Health('body', row.body),
        fuel = fuel, fuelOnClient = not MDP.Props.FuelServerCapable(), mileage = tonumber(row.mileage) or 0.0,
    }, ownerSrc)
    return veh
end

--- Server spawn. Caller holds the plate lock and checked GetSpawnedEntity(plate) == nil.
--- Never throws (H1): returns veh, netId | nil, 'spawn_failed'.
function MDP.Props.SpawnVehicle(row, x, y, z, heading, ownerSrc)
    local holder = {}
    local ok, veh = pcall(doSpawn, holder, row, x, y, z, heading, ownerSrc)
    if not ok or not veh then
        if not ok then print(('^1[mdp_garages] spawn error %s: %s^0'):format(tostring(row.plate), tostring(veh))) end
        local h = holder.veh
        if h and h ~= 0 and DoesEntityExist(h) then DeleteEntity(h) end -- N3: never leave an untracked entity
        return nil, 'spawn_failed'
    end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    Security.TrackSpawn(row.plate, netId, ownerSrc)
    MDP.Props.StampMileage(row.plate)
    return veh, netId
end

--- Permanent keys AFTER the entity exists (qbx_vehiclekeys needs the entity). Never throws.
function MDP.Props.GiveKeys(src, veh, plate)
    if not (Bridge.Keys and type(Bridge.Keys.GiveKeys) == 'function') then return false end
    local ok, res = pcall(Bridge.Keys.GiveKeys, src, veh or plate)
    if not ok or res == false then
        print(('^3[mdp_garages] GiveKeys failed for %s (src %s)^0'):format(tostring(plate), tostring(src)))
        return false
    end
    return true
end

--- Guarded optional bridge hooks: MDP.Props.Hook(Bridge.FrameworkSync, 'OnStore', ...). Never throws.
function MDP.Props.Hook(tbl, fn, ...)
    if type(tbl) == 'table' and type(tbl[fn]) == 'function' then
        local ok, err = pcall(tbl[fn], ...)
        if not ok then print(('^3[mdp_garages] hook %s failed: %s^0'):format(fn, tostring(err))) end
    end
end
