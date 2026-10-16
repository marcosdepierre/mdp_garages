-- okokBilling adapter (paid/escrowed). Source: docs.okokscripts.io/scripts/okokbilling/snippets
-- Documented: TriggerServerEvent("okokBilling:CreateCustomInvoice", target, price, reason, invoiceSource, society, societyName, authorIdentifier)
-- UNVERIFIED: invoking it server-side with TriggerEvent (no client source). No documented paid event -> SupportsPaidHook = false;
-- invoice id not returned, so fineId cannot be linked; players settle via /mdp_payfine or UI.
if not Bridge.IsServer then return end
local RES = 'okokBilling'

CreateThread(function()
    local st = GetResourceState(RES)
    if st == 'started' or st == 'starting' then
        print('^3[mdp_garages] okokBilling detectado: NO se usa para multas (sin hook de pago); las multas se cobran por canal interno (/mdp_payfine o UI). Solo tasas en Config.ChargeMode = \'invoice\'.^0')
    end
end)

Bridge.RegisterAdapter('billing', RES, {
    SupportsPaidHook = false,
    SupportsFines = false, -- Senior decision: no paid hook -> fines always go 'internal'; okok only for fees (ChargeMode='invoice')
    SendBill = function(src, target, amount, reason, society, meta)
        if not Bridge.ValidAmount(amount) then return false end
        local label = meta and meta.fineId and ('%s (#%d)'):format(reason or 'Multa', meta.fineId) or reason
        TriggerEvent('okokBilling:CreateCustomInvoice', target, amount, label, 'mdp_garages', society, society,
            (src and src > 0 and Bridge.GetIdentifier(src)) or nil)
        return true
    end,
})
