if Bridge.Framework ~= 'qbx' then return end
local qbx = exports.qbx_core

if Bridge.IsServer then
    function Bridge.GetPlayer(src) return qbx:GetPlayer(src) end
    function Bridge.GetIdentifier(src)
        local p = qbx:GetPlayer(src); return p and p.PlayerData.citizenid or nil
    end
    function Bridge.GetJob(src)
        local p = qbx:GetPlayer(src); if not p then return nil end
        local j = p.PlayerData.job
        local duty = j.onduty == true
        return { name = j.name, grade = j.grade and j.grade.level or 0, onduty = duty, onDuty = duty }
    end
    function Bridge.GetMoney(src, account)
        if account ~= 'cash' and account ~= 'bank' then return 0 end
        return qbx:GetMoney(src, account) or 0
    end
    function Bridge.RemoveMoney(src, account, amount, reason)
        if not Bridge.ValidAmount(amount) then return false end
        if account ~= 'cash' and account ~= 'bank' then return false end
        return qbx:RemoveMoney(src, account, amount, reason) == true
    end
    function Bridge.FrameworkNotify(src, msg, ntype)
        qbx:Notify(src, msg, ntype)
    end
else
    function Bridge.FrameworkNotify(msg, ntype) exports.qbx_core:Notify(msg, ntype) end
    function Bridge.GetPlayerData() return exports.qbx_core:GetPlayerData() end
end
