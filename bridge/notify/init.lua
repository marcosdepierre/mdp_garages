-- Notify loader. Order: explicit Config.Notify adapter -> ox_lib (mandatory dependency) -> nothing else needed.
-- Config.Notify: 'auto' | 'ox_lib' -> ox_lib; 'framework' -> started core's adapter (qbx_core/qb-core/es_extended);
-- any other value -> that registered adapter. Adapters implement { Server = fn(src,msg,type), Client = fn(msg,type) }.
local OX_TYPES = { info = 'inform', inform = 'inform', primary = 'inform', success = 'success', error = 'error', warning = 'warning', warn = 'warning' }
local CORE = { qbx = 'qbx_core', qb = 'qb-core', esx = 'es_extended' }

local function explicitAdapter()
    local setting = Config.Notify or 'auto'
    if setting == 'auto' or setting == 'ox_lib' then return nil end
    if setting == 'framework' then setting = CORE[Bridge.Framework] end
    if not setting then return nil end
    return Bridge.ResolveAdapter('notify', setting, {})
end

local function oxType(t) return OX_TYPES[t or 'inform'] or 'inform' end

if Bridge.IsServer then
    function Bridge.Notify(src, msg, ntype)
        local impl = explicitAdapter()
        if impl and Bridge.SafeCall(impl, 'Server', src, msg, ntype) then return end
        -- ox_lib is mandatory: its client event always exists, so no further fallback is needed
        TriggerClientEvent('ox_lib:notify', src, { description = tostring(msg), type = oxType(ntype) })
    end
else
    function Bridge.Notify(msg, ntype)
        local impl = explicitAdapter()
        if impl and Bridge.SafeCall(impl, 'Client', msg, ntype) then return end
        if pcall(lib.notify, { description = tostring(msg), type = oxType(ntype) }) then return end
        pcall(Bridge.FrameworkNotify, msg, ntype) -- only if lib.notify itself errored
    end
end
