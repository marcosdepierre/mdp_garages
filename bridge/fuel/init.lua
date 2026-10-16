-- fuel loader (interface only). Adapters are written by Integrations: see docs/integrations.md.
-- Config.Fuel = 'auto' or a resource name. Priority when auto: 'ox_fuel', 'cdn-fuel', 'LegacyFuel'
local PRIORITY = { 'ox_fuel', 'cdn-fuel', 'LegacyFuel' }
Bridge.Fuel = Bridge.Fuel or {}

function Bridge.Fuel.Get()
    return Bridge.ResolveAdapter('fuel', Config.Fuel or 'auto', PRIORITY)
end

-- Bridge.Fuel.Call(fnName, ...) -> result or fallback value (nil). Never throws.
-- Expected adapter functions: GetFuel(vehicle) -> number, SetFuel(vehicle, value) [client]; ox_fuel via Entity(veh).state.fuel (state bag, so it also works SERVER-side)
function Bridge.Fuel.Call(fnName, fallback, ...)
    local impl = Bridge.Fuel.Get()
    local ok, res = Bridge.SafeCall(impl, fnName, ...)
    if ok then return res end
    -- no adapter / adapter failed: native fallback (Bridge.FuelCommon, Integrations' _native.lua)
    local FC = Bridge.FuelCommon
    if FC then
        local native = (fnName == 'GetFuel' and FC.Get) or (fnName == 'SetFuel' and FC.Set) or nil
        if native then
            local okN, resN = pcall(native, ...)
            if okN then return resN end
        end
    end
    return fallback
end

-- Phase 1 API (Integrations contract). ServerCapable is true only for ox_fuel (state bag); guards when absent.
if not Bridge.Fuel.ServerCapable then
    function Bridge.Fuel.ServerCapable()
        local FC = Bridge.FuelCommon
        if not (FC and FC.ServerCapable) then return false end
        local ok, res = pcall(FC.ServerCapable)
        return ok and res == true
    end
end
if not Bridge.Fuel.GetFuel then
    function Bridge.Fuel.GetFuel(veh) return Bridge.Fuel.Call('GetFuel', nil, veh) end
end
if not Bridge.Fuel.SetFuel then
    function Bridge.Fuel.SetFuel(veh, v) return Bridge.Fuel.Call('SetFuel', false, veh, v) end
end
