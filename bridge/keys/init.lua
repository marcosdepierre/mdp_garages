-- keys loader (interface only). Adapters are written by Integrations: see docs/integrations.md.
-- Config.Keys = 'auto' or a resource name. Priority when auto: 'qbx_vehiclekeys', 'qb-vehiclekeys'
local PRIORITY = { 'qbx_vehiclekeys', 'qb-vehiclekeys' }
Bridge.Keys = Bridge.Keys or {}

function Bridge.Keys.Get()
    return Bridge.ResolveAdapter('keys', Config.Keys or 'auto', PRIORITY)
end

-- Bridge.Keys.Call(fnName, ...) -> result or fallback value (nil). Never throws.
-- Expected adapter functions: GiveKeys(src|plate, plate), RemoveKeys(src, plate), HasKeys(src, plate)
function Bridge.Keys.Call(fnName, fallback, ...)
    local impl = Bridge.Keys.Get()
    local ok, res = Bridge.SafeCall(impl, fnName, ...)
    if ok then return res end
    return fallback
end
