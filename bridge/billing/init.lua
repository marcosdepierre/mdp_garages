-- billing loader (interface only). Adapters are written by Integrations: see docs/integrations.md.
-- Config.Billing = 'auto' or a resource name. Priority when auto: 'okokBilling', 'esx_billing', 'qb-phone'
local PRIORITY = { 'okokBilling', 'esx_billing', 'qb-phone' }
Bridge.Billing = Bridge.Billing or {}

function Bridge.Billing.Get()
    return Bridge.ResolveAdapter('billing', Config.Billing or 'auto', PRIORITY)
end

-- Bridge.Billing.Call(fnName, ...) -> result or fallback value (nil). Never throws.
-- Expected adapter functions: SendBill(src, target, amount, reason, society) [server]
function Bridge.Billing.Call(fnName, fallback, ...)
    local impl = Bridge.Billing.Get()
    local ok, res = Bridge.SafeCall(impl, fnName, ...)
    if ok then return res end
    return fallback
end

---------------------------------------------------------------------------
-- Fines integration (server). Payment hook contract for adapters:
--   SendBill(src, target, amount, reason, society, meta)  meta = { fineId = integer }
--   Optional: adapter.SupportsPaidHook = true when the billing resource exposes a
--   "bill paid" event/export. On payment the adapter MUST call (server side):
--       Bridge.Billing.MarkFinePaid(fineId, source)   -> boolean
--   fineId = mdp_fines.id passed in meta. Never trust amounts from the billing event.
---------------------------------------------------------------------------
if Bridge.IsServer then
    --- Marks an mdp_fines row paid exactly once (atomic). Returns true if it changed.
    function Bridge.Billing.MarkFinePaid(fineId, source)
        if math.type(fineId) ~= 'integer' then
            fineId = tonumber(fineId); if not fineId or fineId % 1 ~= 0 then return false end
            fineId = math.tointeger(fineId)
        end
        if fineId <= 0 then return false end
        local ok, affected = pcall(MySQL.update.await, 'UPDATE mdp_fines SET paid = 1 WHERE id = ? AND paid = 0', { fineId })
        if ok and affected == 1 then
            TriggerEvent('mdp_garages:server:finePaid', fineId, source or 'billing')
            return true
        end
        return false
    end

    function Bridge.Billing.SupportsPaidHook()
        local impl = Bridge.Billing.Get()
        return impl ~= nil and impl.SupportsPaidHook == true
    end

    --- Issue a fine: always record in mdp_fines, then try the billing adapter.
    ---@return integer|nil fineId, boolean billed
    function Bridge.Billing.IssueFine(officerSrc, targetSrc, plate, owner, amount, reason, issuedBy, society)
        if not Bridge.ValidAmount(amount) then return nil, false end
        plate = Utils.NormalizePlate(plate)
        if not Utils.IsValidPlate(plate) or type(owner) ~= 'string' or owner == '' then return nil, false end
        local function clean(v, n)
            if Security and Security.V and Security.V.sanitizeString then return Security.V.sanitizeString(v, n) end
            return (type(v) == 'string' and v:sub(1, n)) or ''
        end
        reason, issuedBy = clean(reason, 255), clean(issuedBy, 64)
        local fineId = MySQL.insert.await(
            'INSERT INTO mdp_fines (plate, owner, amount, reason, issued_by) VALUES (?, ?, ?, ?, ?)',
            { plate, owner, amount, reason, issuedBy })
        if not fineId then return nil, false end
        local billed = false
        if targetSrc then
            billed = Bridge.Billing.Call('SendBill', false, officerSrc, targetSrc, amount, reason, society, { fineId = fineId }) ~= false
                and Bridge.Billing.Get() ~= nil
        end
        -- When billed externally, the invoice is the only payment path (mdp_fine_invoices row,
        -- written by the adapter via BillingCommon.Link); payFine refuses with 'external_invoice'.
        return fineId, billed
    end

    --- True if this fine was sent as an external invoice (row in mdp_fine_invoices).
    function Bridge.Billing.IsExternalInvoice(fineId)
        local ok, r = pcall(MySQL.scalar.await, 'SELECT 1 FROM mdp_fine_invoices WHERE fine_id = ? LIMIT 1', { fineId })
        return ok and r ~= nil
    end
end
