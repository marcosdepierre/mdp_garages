-- esx_billing adapter. Source: github.com/esx-framework/ESX-Legacy-Addons [esx_addons]/esx_billing/server/main.lua
-- exports.esx_billing:BillPlayer(targetId, senderIdentifier, sharedAccountName, label, amount) -> insertedId|false
-- TriggerEvent('esx_billing:paidBill', source, billId) on payment -> SupportsPaidHook = true
if not Bridge.IsServer then return end
local RES = 'esx_billing'

Bridge.RegisterAdapter('billing', RES, {
    SupportsPaidHook = true,
    SupportsFines = true,
    SendBill = function(src, target, amount, reason, society, meta)
        if not Bridge.ValidAmount(amount) then return false end
        local sender = (src and src > 0 and Bridge.GetIdentifier(src)) or 'server'
        local id = exports[RES]:BillPlayer(target, sender, society and ('society_' .. society) or 'society_police', reason, amount)
        if not id then return false end
        -- Invoice exists from here on: never report failure (that would reopen the fine as 'internal').
        -- If the link fails, Link logs it and IssueFine sees HasInvoice == false -> channel 'needs_review'.
        local linked = Bridge.BillingCommon.SafeLink(RES, id, meta)
        if not linked then print(('^1[mdp_garages][billing] %s: factura %s creada sin enlace (fine=%s) -> needs_review^0'):format(RES, tostring(id), tostring(meta and meta.fineId))) end
        return true
    end,
})

AddEventHandler('esx_billing:paidBill', function(src, billId)
    if GetInvokingResource() ~= RES then return end
    Bridge.BillingCommon.OnPaid(RES, billId, src)
end)
