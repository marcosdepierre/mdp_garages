-- phone loader (interface only). Adapters are written by Integrations: see docs/integrations.md.
-- Config.Phone = 'auto' or a resource name. Priority when auto: 'lb-phone', 'npwd', 'qb-phone'
local PRIORITY = { 'lb-phone', 'npwd', 'qb-phone' }
Bridge.Phone = Bridge.Phone or {}

function Bridge.Phone.Get()
    return Bridge.ResolveAdapter('phone', Config.Phone or 'auto', PRIORITY)
end

-- Bridge.Phone.Call(fnName, ...) -> result or fallback value (nil). Never throws.
-- Expected adapter functions: RegisterApp(def), SendNotification(src, data)
function Bridge.Phone.Call(fnName, fallback, ...)
    local impl = Bridge.Phone.Get()
    local ok, res = Bridge.SafeCall(impl, fnName, ...)
    if ok then return res end
    return fallback
end
