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
    return fallback
end
