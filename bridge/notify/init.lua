-- Notify loader. Priority: explicit Config.Notify adapter -> ox_lib (mandatory) -> framework native.
-- Adapters (Integrations Engineer) implement { Server = fn(src,msg,type), Client = fn(msg,type) }.
local function adapter()
    local setting = Config.Notify or 'auto'
    if setting == 'auto' or setting == 'ox_lib' then return nil end
    return Bridge.ResolveAdapter('notify', setting, {})
end

if Bridge.IsServer then
    function Bridge.Notify(src, msg, ntype)
        local impl = adapter()
        if impl and Bridge.SafeCall(impl, 'Server', src, msg, ntype) then return end
        if pcall(TriggerClientEvent, 'ox_lib:notify', src, { description = msg, type = ntype or 'inform' }) then return end
        if not pcall(Bridge.FrameworkNotify, src, msg, ntype) then
            TriggerClientEvent('mdp_garages:client:notify', src, msg, ntype)
        end
    end
else
    function Bridge.Notify(msg, ntype)
        local impl = adapter()
        if impl and Bridge.SafeCall(impl, 'Client', msg, ntype) then return end
        if pcall(lib.notify, { description = msg, type = ntype or 'inform' }) then return end
        pcall(Bridge.FrameworkNotify, msg, ntype)
    end
end
