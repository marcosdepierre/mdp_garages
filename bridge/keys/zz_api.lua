-- Public keys API (Integrations). Server: Bridge.Keys.GiveKeys/RemoveKeys/HasKeys(src, vehicle entity|plate) -> boolean.
-- mdp_vehicle_keys stays authoritative (Backend); this only mirrors physical access to the external key resource.
-- No adapter -> true (mdp's own table is the fallback key store; nothing external to update).
Bridge.Keys = Bridge.Keys or {}
local function resolve()
    if not Bridge.Keys.Get then return nil end
    local ok, impl, res = pcall(Bridge.Keys.Get)
    if ok then return impl, res end
    return nil
end

local function run(fn, src, vehicle)
    local impl, res = resolve()
    if not impl then return true end
    if type(impl[fn]) ~= 'function' then return false end
    local ok, r = pcall(impl[fn], src, vehicle)
    if not ok then
        print(('^1[mdp_garages][keys] %s.%s failed: %s^0'):format(tostring(res), fn, tostring(r)))
        return false
    end
    return r == true
end

if IsDuplicityVersion() then
    function Bridge.Keys.GiveKeys(src, vehicle) return run('GiveKeys', src, vehicle) end
    function Bridge.Keys.RemoveKeys(src, vehicle) return run('RemoveKeys', src, vehicle) end
    --- nil when no external resource (caller should check mdp_vehicle_keys)
    function Bridge.Keys.HasKeys(src, vehicle)
        if not resolve() then return nil end
        return run('HasKeys', src, vehicle)
    end
else
    function Bridge.Keys.HasKeys(vehicle)
        local impl = resolve(); if not impl then return nil end
        local ok, r = pcall(impl.HasKeys or function() return false end, vehicle)
        return ok and r == true
    end
end

if IsDuplicityVersion() then
    --- Store rule (Config.RemoveKeysOnStore, default true): on store to a garage (GARAGED) remove the storing
    --- player's TEMPORARY keys from the external key resource; keep them when parked in the world (PARKED_WORLD).
    --- Never touches mdp_vehicle_keys (phase-3 shared keys). Returns true if keys were removed.
    function Bridge.Keys.OnStore(src, plate, newState)
        if Config.RemoveKeysOnStore == false then return false end
        if newState ~= Constants.VehicleState.GARAGED then return false end
        local ok, res = pcall(Bridge.Keys.RemoveKeys, src, plate)
        if not ok then print('^1[mdp_garages][keys] OnStore failed: ' .. tostring(res) .. '^0') return false end
        return res == true
    end
end
