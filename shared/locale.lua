Locales = Locales or {}
local warned = {}

local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    print('^3[mdp_garages] ' .. msg .. '^0')
end

--- Translate key with optional format args. Never throws.
function _L(key, ...)
    local lang = Locales[Config.Locale]
    if not lang then
        warnOnce('__locale', ('locale "%s" not found, using en'):format(tostring(Config.Locale)))
        lang = Locales.en or {}
    end
    local str = lang[key] or (Locales.en and Locales.en[key])
    if not str then
        warnOnce(key, 'missing locale key: ' .. tostring(key))
        return tostring(key)
    end
    if select('#', ...) > 0 then
        local ok, res = pcall(string.format, str, ...)
        if ok then return res end
        warnOnce('fmt:' .. key, 'bad format args for locale key: ' .. tostring(key))
    end
    return str
end

--- UI strings table for the NUI: active locale's `ui` merged over English (missing keys fall back).
Utils = Utils or {}
function Utils.UILocale()
    local out = {}
    for k, v in pairs((Locales.en and Locales.en.ui) or {}) do out[k] = v end
    local lang = Locales[Config.Locale]
    for k, v in pairs((lang and lang.ui) or {}) do out[k] = v end
    return out
end
