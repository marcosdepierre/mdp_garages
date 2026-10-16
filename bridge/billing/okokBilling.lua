-- okokBilling adapter (paid/escrowed). Source: docs.okokscripts.io/scripts/okokbilling/snippets
-- Documented: TriggerServerEvent("okokBilling:CreateCustomInvoice", target, price, reason, invoiceSource, society, societyName, authorIdentifier)
-- UNVERIFIED: invoking it server-side with TriggerEvent (no client source). No documented paid event -> SupportsPaidHook = false;
-- invoice id not returned, so fineId cannot be linked; players settle via /mdp_payfine or UI.
if not Bridge.IsServer then return end
local RES = 'okokBilling'

Bridge.RegisterAdapter('billing', RES, {
    SupportsPaidHook = false,
    SendBill = function(src, target, amount, reason, society, meta)
        if not Bridge.ValidAmount(amount) then return false end
        local label = meta and meta.fineId and ('%s (#%d)'):format(reason or 'Multa', meta.fineId) or reason
        TriggerEvent('okokBilling:CreateCustomInvoice', target, amount, label, 'mdp_garages', society, society,
            (src and src > 0 and Bridge.GetIdentifier(src)) or nil)
        return true
    end,
})
