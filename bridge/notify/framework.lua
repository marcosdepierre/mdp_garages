-- Framework-native notify adapters, keyed by core resource name (es_extended | qb-core | qbx_core).
-- ESX: ESX.ShowNotification(msg, type) / esx:showNotification ; QB: QBCore.Functions.Notify(text, type) / QBCore:Notify ;
-- Qbox: exports.qbx_core:Notify([src,] text, type). All already wrapped by Bridge.FrameworkNotify in bridge/framework/*.lua.
local QB_TYPES = { info = 'primary', inform = 'primary', success = 'success', error = 'error', warning = 'warning' }
local function norm(fw, t)
    t = t or 'info'
    if fw == 'qb' then return QB_TYPES[t] or 'primary' end
    if fw == 'qbx' then return t == 'info' and 'inform' or t end
    return t
end
for res, fw in pairs({ ['es_extended'] = 'esx', ['qb-core'] = 'qb', ['qbx_core'] = 'qbx' }) do
    Bridge.RegisterAdapter('notify', res, {
        Server = function(src, msg, ntype)
            if Bridge.Framework ~= fw then return false end
            Bridge.FrameworkNotify(src, msg, norm(fw, ntype)) return true
        end,
        Client = function(msg, ntype)
            if Bridge.Framework ~= fw then return false end
            Bridge.FrameworkNotify(msg, norm(fw, ntype)) return true
        end,
    })
end
