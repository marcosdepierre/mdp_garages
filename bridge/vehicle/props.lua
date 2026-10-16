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
local function localSanitize(raw, expectedPlate)
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

--- Public sanitizer. On the server, when Security.SanitizeProps exists (31ffb8d) it is the single validator:
--- dbRow {plate, model, mileage} is read from mdp_vehicles by plate when not given. Otherwise local fallback.
---@return table|nil clean, string|nil json_or_err
function Bridge.Props.Sanitize(raw, expectedPlate, dbRow, entity)
    if IsDuplicityVersion() and Security and type(Security.SanitizeProps) == 'function' then
        local t = raw
        if type(raw) == 'string' then
            if #raw > MAX_JSON then return nil, 'too_large' end
            local ok, dec = pcall(json.decode, raw); t = ok and dec or nil
        end
        if type(t) ~= 'table' then return nil, 'invalid_props' end
        if not dbRow and expectedPlate then
            local ok, row = pcall(MySQL.single.await, 'SELECT plate, model, mileage FROM mdp_vehicles WHERE plate = ?', { expectedPlate })
            dbRow = ok and row or nil
        end
        local ok, clean, err, encoded = pcall(Security.SanitizeProps, t, dbRow, entity)
        if not ok then return nil, 'sanitize_error' end
        if not clean then return nil, err end
        return clean, encoded or json.encode(clean)
    end
    return localSanitize(raw, expectedPlate)
end

local BAG = 'mdp:props'           -- entity state bag (server-set, replicated)
local ACK = 'mdp_garages:server:propsApplied'    -- client -> server (netId)
local FAIL = 'mdp_garages:client:propsApplyFailed' -- server -> client (netId)
local LOCAL_DONE = 'mdp_garages:client:propsApplied' -- client-local only (netId, ok); never networked

if IsDuplicityVersion() then
    ---------------------------------------------------------------------------
    -- Server: request apply with timeout + one retry
    ---------------------------------------------------------------------------
    local pending = {} -- netId -> { veh, payload, tries, src, token }
    local TIMEOUT = 5000

    local function fail(netId, p, silent)
        pending[netId] = nil
        if not silent then print(('^1[mdp_garages][props] apply not acknowledged for netId %d after retry^0'):format(netId)) end
        local targets = {}
        if p.src then targets[p.src] = true end
        if DoesEntityExist(p.veh) then
            local owner = NetworkGetEntityOwner(p.veh)
            if owner and owner > 0 then targets[owner] = true end
            Entity(p.veh).state:set(BAG, nil, true)
        end
        for t in pairs(targets) do TriggerClientEvent(FAIL, t, netId) end
    end

    local function arm(netId, token)
        SetTimeout(TIMEOUT, function()
            local p = pending[netId]
            if not p or p.token ~= token then return end
            if not DoesEntityExist(p.veh) then pending[netId] = nil return end
            if p.tries >= 2 then return fail(netId, p) end
            p.tries = p.tries + 1
            p.token = token + 1
            local bag = Entity(p.veh).state
            bag:set(BAG, nil, true)       -- re-set so the (possibly new) owner sees a change
            bag:set(BAG, p.payload, true)
            arm(netId, p.token)
        end)
    end

    --- Server-driven props apply. payload = JSON string or table (Backend: {props, engine, body, fuel, fuelOnClient, mileage}).
    --- src (optional): spawning player, notified on final failure. Returns boolean (request armed).
    function Bridge.Props.RequestApply(veh, payload, src)
        if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
        if payload == nil or (type(payload) == 'string' and #payload > MAX_JSON) then return false end
        local netId = NetworkGetNetworkIdFromEntity(veh)
        pending[netId] = { veh = veh, payload = payload, tries = 1, src = tonumber(src), token = 1 }
        Entity(veh).state:set(BAG, payload, true)
        arm(netId, 1)
        return true
    end

    local NACK_REASONS = { model_mismatch = true, invalid_props = true } -- deterministic: no retry

    --- Ack from the owning client: (netId, ok, reason?). ok ~= false = applied; ok == false + whitelisted reason
    --- = deterministic failure -> clear bag, cancel timer (pending removed), log, notify spawner + owner.
    RegisterNetEvent(ACK, function(netId, ok, reason)
        local src = source
        if Security and Security.RateLimit and not Security.RateLimit(src, 'ev:propsApplied', 10, 5000) then return end
        netId = math.tointeger(tonumber(netId))
        if not netId or netId <= 0 or netId > 0xFFFF then return end
        local p = pending[netId]; if not p then return end
        if not DoesEntityExist(p.veh) or NetworkGetEntityOwner(p.veh) ~= src then
            if Security and Security.LogReject then Security.LogReject(src, ACK, 'not_owner') end
            return
        end
        if ok == false then
            if type(reason) ~= 'string' or not NACK_REASONS[reason] then
                if Security and Security.LogReject then Security.LogReject(src, ACK, 'bad_nack_reason') end
                return
            end
            print(('^1[mdp_garages][props] apply failed for netId %d (owner %d): %s^0'):format(netId, src, reason))
            return fail(netId, p, true) -- clears bag, removes pending (timer becomes a no-op), notifies
        end
        pending[netId] = nil -- cancels timer (token check)
        Entity(p.veh).state:set(BAG, nil, true) -- clear: applied once
    end)
    return
end



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

-- Applier (single applier; replaces client/props.lua's). Value: JSON string or Backend table
-- { props, engine, body, fuel, fuelOnClient, mileage }. Applies when this client is (or becomes, within 5 s)
-- NetworkGetEntityOwner; then acks to the server, which clears the bag. Emits local LOCAL_DONE(netId, ok).
local applying = {} -- bagName -> true while a worker runs

local function decode(v)
    if type(v) == 'string' then local ok, d = pcall(json.decode, v); return ok and d or nil end
    return type(v) == 'table' and v or nil
end

local function u32(h) h = math.tointeger(tonumber(h)); return h and (h & 0xFFFFFFFF) or nil end

--- Deterministic checks before applying. Returns nil or a whitelisted reason ('model_mismatch'|'invalid_props').
local function precheck(veh, v)
    local props = v.props ~= nil and v.props or (v.model ~= nil and v or nil)
    if type(props) == 'string' then local ok, d = pcall(json.decode, props); props = ok and d or false end
    if props == false or (props ~= nil and type(props) ~= 'table') then return 'invalid_props' end
    if props and props.model ~= nil then
        local m = props.model
        if type(m) == 'string' then m = joaat(m) end
        if u32(m) == nil or u32(m) ~= u32(GetEntityModel(veh)) then return 'model_mismatch' end
    end
    return nil
end

local function applyPayload(veh, v)
    local props = v.props ~= nil and v.props or (v.model ~= nil and v or nil) -- bare props table/json also accepted
    local ok = true
    if props then ok = Bridge.Props.Apply(veh, props) and ok end
    if v.engine then SetVehicleEngineHealth(veh, v.engine + 0.0) end
    if v.body then SetVehicleBodyHealth(veh, v.body + 0.0) end
    if v.fuel and v.fuelOnClient ~= false and Bridge.Fuel and Bridge.Fuel.Call then
        Bridge.Fuel.Call('SetFuel', nil, veh, Bridge.FuelCommon.Clamp(v.fuel))
    end
    return ok
end

AddStateBagChangeHandler(BAG, nil, function(bagName, _, value)
    if value == nil or applying[bagName] then return end
    local v = decode(value) -- nil -> invalid payload (reported as invalid_props once we own the entity)
    applying[bagName] = true
    CreateThread(function()
        local deadline, veh = GetGameTimer() + 5000, 0
        while GetGameTimer() < deadline do
            veh = GetEntityFromStateBagName(bagName)
            if veh ~= 0 and DoesEntityExist(veh) and NetworkGetEntityOwner(veh) == PlayerId() then
                if NetworkHasControlOfEntity(veh) then break end
                NetworkRequestControlOfEntity(veh)
            end
            Wait(100)
        end
        applying[bagName] = nil
        if veh == 0 or not DoesEntityExist(veh) or NetworkGetEntityOwner(veh) ~= PlayerId() then return end -- not ours: new owner handles retry
        local netId = NetworkGetNetworkIdFromEntity(veh)
        local reason = (not v) and 'invalid_props' or precheck(veh, v)
        if reason then -- deterministic failure: immediate negative ack, no retry (server sends FAIL -> LOCAL_DONE false)
            print('^3[mdp_garages][props] not applied: ' .. reason .. '^0')
            TriggerServerEvent(ACK, netId, false, reason)
            return
        end
        local okCall, res = pcall(applyPayload, veh, v)
        local ok = okCall and res ~= false
        if not okCall then print('^3[mdp_garages][props] apply failed: ' .. tostring(res) .. '^0') end
        if ok then TriggerServerEvent(ACK, netId, true) end -- transient failure: no ack -> server retries once, then FAIL
        if ok then TriggerEvent(LOCAL_DONE, netId, true) end
    end)
end)

RegisterNetEvent(FAIL, function(netId)
    netId = math.tointeger(tonumber(netId)); if not netId then return end
    TriggerEvent(LOCAL_DONE, netId, false)
end)
