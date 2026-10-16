if Bridge.Framework ~= 'esx' then return end
local ESX = exports['es_extended']:getSharedObject()

if Bridge.IsServer then
    local accMap = { cash = 'money', bank = 'bank' }
    function Bridge.GetPlayer(src) return ESX.GetPlayerFromId(src) end
    function Bridge.GetIdentifier(src)
        local p = ESX.GetPlayerFromId(src); return p and p.identifier or nil
    end
    function Bridge.GetJob(src)
        local p = ESX.GetPlayerFromId(src); if not p then return nil end
        local j = p.getJob()
        -- Only trust ESX duty when it is a real boolean; older ESX has no duty system.
        local duty, assumed = j.onDuty, false
        if type(duty) ~= 'boolean' then
            duty, assumed = (Config.ESXAssumeOnDuty ~= false), true
        end
        return { name = j.name, grade = j.grade, onduty = duty, onDuty = duty, dutyAssumed = assumed }
    end
    function Bridge.GetMoney(src, account)
        local p = ESX.GetPlayerFromId(src); local a = accMap[account]
        if not p or not a then return 0 end
        local acc = p.getAccount(a); return acc and acc.money or 0
    end
    function Bridge.RemoveMoney(src, account, amount, reason)
        if not Bridge.ValidAmount(amount) then return false end
        local p = ESX.GetPlayerFromId(src); local a = accMap[account]
        if not p or not a then return false end
        local acc = p.getAccount(a)
        if not acc or acc.money < amount then return false end
        p.removeAccountMoney(a, amount, reason)
        return true
    end
    function Bridge.FrameworkNotify(src, msg, ntype)
        TriggerClientEvent('esx:showNotification', src, msg, ntype)
    end
else
    function Bridge.FrameworkNotify(msg, ntype) ESX.ShowNotification(msg, ntype) end
    function Bridge.GetPlayerData() return ESX.GetPlayerData() end
end
