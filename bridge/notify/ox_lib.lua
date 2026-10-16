-- ox_lib notify adapter (default). Docs: https://overextended.dev/ox_lib/Modules/Interface/Client/notify
-- Note: notify/init.lua already calls lib.notify directly for 'auto'/'ox_lib'; this adapter is used if resolution changes.
local TYPES = { info = 'inform', inform = 'inform', success = 'success', error = 'error', warning = 'warning' }
local function data(msg, ntype)
    return { description = tostring(msg), type = TYPES[ntype or 'info'] or 'inform' }
end
Bridge.RegisterAdapter('notify', 'ox_lib', {
    Server = function(src, msg, ntype) TriggerClientEvent('ox_lib:notify', src, data(msg, ntype)) return true end,
    Client = function(msg, ntype) lib.notify(data(msg, ntype)) return true end,
})
