-- qb-phone invoices adapter. Source: github.com/qbcore-framework/qb-phone server.lua
-- No bill export: same INSERT as qb-phone's /bill command, then TriggerClientEvent('qb-phone:RefreshPhone', target).
-- Paid hook: TriggerEvent('qb-phone:server:paidInvoice', source, invoiceId) -> SupportsPaidHook = true
if not Bridge.IsServer then return end
local RES = 'qb-phone'

Bridge.RegisterAdapter('billing', RES, {
    SupportsPaidHook = true,
    SupportsFines = true,
    SendBill = function(src, target, amount, reason, society, meta)
        if not Bridge.ValidAmount(amount) then return false end
        local cid = Bridge.GetIdentifier(target); if not cid then return false end
        local sender = (src and src > 0 and Bridge.GetIdentifier(src)) or 'mdp_garages'
        local id = MySQL.insert.await(
            'INSERT INTO phone_invoices (citizenid, amount, society, sender, sendercitizenid) VALUES (?, ?, ?, ?, ?)',
            { cid, amount, society or 'police', reason or 'Garage', sender })
        if not id then return false end
        -- Invoice exists from here on: never report failure (that would reopen the fine as 'internal').
        -- If the link fails, Link logs it and IssueFine sees HasInvoice == false -> channel 'needs_review'.
        local linked = Bridge.BillingCommon.SafeLink(RES, id, meta)
        if not linked then print(('^1[mdp_garages][billing] %s: factura %s creada sin enlace (fine=%s) -> needs_review^0'):format(RES, tostring(id), tostring(meta and meta.fineId))) end
        TriggerClientEvent('qb-phone:RefreshPhone', target)
        return true
    end,
})

AddEventHandler('qb-phone:server:paidInvoice', function(src, invoiceId)
    if GetInvokingResource() ~= RES then return end
    Bridge.BillingCommon.OnPaid(RES, invoiceId, src)
end)
