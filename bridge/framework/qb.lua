if Bridge.Framework ~= 'qb' then return end
local QBCore = exports['qb-core']:GetCoreObject()

if Bridge.IsServer then
    function Bridge.GetPlayer(src) return QBCore.Functions.GetPlayer(src) end
    function Bridge.GetIdentifier(src)
        local p = QBCore.Functions.GetPlayer(src); return p and p.PlayerData.citizenid or nil
    end
    function Bridge.GetJob(src)
        local p = QBCore.Functions.GetPlayer(src); if not p then return nil end
        local j = p.PlayerData.job
        local duty = j.onduty == true
        return { name = j.name, grade = j.grade and j.grade.level or 0, onduty = duty, onDuty = duty }
    end
    function Bridge.GetMoney(src, account)
        local p = QBCore.Functions.GetPlayer(src)
        if not p or (account ~= 'cash' and account ~= 'bank') then return 0 end
        return p.PlayerData.money[account] or 0
    end
    function Bridge.RemoveMoney(src, account, amount, reason)
        if not Bridge.ValidAmount(amount) then return false end
        if account ~= 'cash' and account ~= 'bank' then return false end
        local p = QBCore.Functions.GetPlayer(src); if not p then return false end
        return p.Functions.RemoveMoney(account, amount, reason) == true
    end
    function Bridge.FrameworkNotify(src, msg, ntype)
        TriggerClientEvent('QBCore:Notify', src, msg, ntype)
    end
else
    function Bridge.FrameworkNotify(msg, ntype) QBCore.Functions.Notify(msg, ntype) end
    function Bridge.GetPlayerData() return QBCore.Functions.GetPlayerData() end
end
