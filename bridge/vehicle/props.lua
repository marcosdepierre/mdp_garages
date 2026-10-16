-- Vehicle properties bridge (Integrations). Uses ox_lib (mandatory):
--   client: lib.getVehicleProperties(vehicle) -> table|nil · lib.setVehicleProperties(vehicle, props[, fixVehicle]) -> boolean
-- Server never trusts client props blindly: Bridge.Props.Sanitize validates type, size and health/fuel ranges.
Bridge.Props = Bridge.Props or {}
local MAX_JSON = 65535 -- mdp_vehicles.props / player_vehicles.mods / owned_vehicles.vehicle are LONGTEXT; cap anyway
local MAX_DEPTH = 6

local function clampNum(v, lo, hi)
    v = tonumber(v); if not v or v ~= v then return nil end
    return math.max(lo, math.min(hi, v))
end

--- Deep copy keeping only plain data (no functions/userdata), bounded depth.
local function scrub(t, depth)
    if depth > MAX_DEPTH then return nil end
    local out = {}
    for k, v in pairs(t) do
        local tk, tv = type(k), type(v)
        if (tk == 'string' or tk == 'number') then
            if tv == 'table' then out[k] = scrub(v, depth + 1)
            elseif tv == 'number' then if v == v and v ~= math.huge and v ~= -math.huge then out[k] = v end
            elseif tv == 'string' then if #v <= 256 then out[k] = v end
            elseif tv == 'boolean' then out[k] = v end
        end
    end
    return out
end

--- Sanitize props (table or JSON string). Returns propsTable, jsonString  or nil, err.
--- expectedPlate (optional): forces props.plate to the server plate.
function Bridge.Props.Sanitize(raw, expectedPlate)
    local t = raw
    if type(raw) == 'string' then
        if #raw > MAX_JSON then return nil, 'too_large' end
        local ok, dec = pcall(json.decode, raw)
        if not ok then return nil, 'invalid_json' end
        t = dec
    end
    if type(t) ~= 'table' then return nil, 'invalid_props' end
    t = scrub(t, 1)
    if expectedPlate then t.plate = expectedPlate end
    t.fuelLevel     = t.fuelLevel     ~= nil and clampNum(t.fuelLevel, 0, 100) or nil
    t.engineHealth  = t.engineHealth  ~= nil and clampNum(t.engineHealth, -4000, 1000) or nil
    t.bodyHealth    = t.bodyHealth    ~= nil and clampNum(t.bodyHealth, 0, 1000) or nil
    t.tankHealth    = t.tankHealth    ~= nil and clampNum(t.tankHealth, -1000, 1000) or nil
    t.dirtLevel     = t.dirtLevel     ~= nil and clampNum(t.dirtLevel, 0, 15) or nil
    local ok, enc = pcall(json.encode, t)
    if not ok or type(enc) ~= 'string' then return nil, 'encode_failed' end
    if #enc > MAX_JSON then return nil, 'too_large' end
    return t, enc
end

if IsDuplicityVersion() then return end

---------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------
--- Reads props of a vehicle (client). Returns table|nil.
function Bridge.Props.Get(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    local ok, props = pcall(lib.getVehicleProperties, veh)
    if not ok or type(props) ~= 'table' then
        print('^3[mdp_garages][props] getVehicleProperties failed: ' .. tostring(props) .. '^0')
        return nil
    end
    -- fuel from the fuel bridge (adapter value, clamped 0-100) overrides the native read
    if Bridge.Fuel and Bridge.Fuel.Call then
        local f = Bridge.Fuel.Call('GetFuel', nil, veh)
        if type(f) == 'number' then props.fuelLevel = Bridge.FuelCommon.Clamp(f) end
    end
    return props
end

--- Applies props (table or JSON) to a vehicle the local client owns. Returns boolean.
function Bridge.Props.Apply(veh, raw)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local props = raw
    if type(raw) == 'string' then
        local ok, dec = pcall(json.decode, raw); props = ok and dec or nil
    end
    if type(props) ~= 'table' then return false end
    local ok, res = pcall(lib.setVehicleProperties, veh, props)
    if not ok then print('^3[mdp_garages][props] setVehicleProperties failed: ' .. tostring(res) .. '^0') return false end
    -- LegacyFuel/cdn-fuel keep their own value: must be set on the owning client after spawn
    if props.fuelLevel and Bridge.Fuel and Bridge.Fuel.Call then Bridge.Fuel.Call('SetFuel', nil, veh, props.fuelLevel) end
    return res ~= false
end

-- Applier for server-spawned vehicles: server sets Entity(veh).state.mdp_props (JSON, replicated).
-- Only the network owner applies, once per entity (props are networked by the game after that).
local applied = {}
AddStateBagChangeHandler('mdp_props', nil, function(bagName, _, value)
    if type(value) ~= 'string' then return end
    local veh = GetEntityFromStateBagName(bagName)
    local t = GetGameTimer() + 5000
    while (veh == 0 or not DoesEntityExist(veh)) and GetGameTimer() < t do Wait(50); veh = GetEntityFromStateBagName(bagName) end
    if veh == 0 or not DoesEntityExist(veh) or applied[veh] then return end
    if NetworkGetEntityOwner(veh) ~= PlayerId() then return end
    applied[veh] = true
    Bridge.Props.Apply(veh, value)
    SetTimeout(60000, function() applied[veh] = nil end)
end)
