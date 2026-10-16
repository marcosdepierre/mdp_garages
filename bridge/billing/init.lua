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

    --- Issue a fine. Always recorded in mdp_fines; channel decides the payment path:
    ---   'invoice'      adapter supports fines (SupportsFines ~= false) -> paid in the resource; paid hook -> MarkFinePaid
    ---   'internal'     no adapter, adapter.SupportsFines == false (okokBilling), or SendBill failed without a linked invoice
    ---   'needs_review' SendBill returned true but no invoice got linked (BillingCommon.HasInvoice false); blocked
    ---                  from payFine, resolved by staff (/mdp_finereview, server/fine_review.lua)
    --- 'external' stays in the ENUM but is unused for fines.
    ---@return integer|nil fineId, string|nil channel
    function Bridge.Billing.IssueFine(officerSrc, targetSrc, plate, owner, amount, reason, issuedBy, society)
        if not Bridge.ValidAmount(amount) then return nil end
        plate = Utils.NormalizePlate(plate)
        if not Utils.IsValidPlate(plate) or type(owner) ~= 'string' or owner == '' then return nil end
        local function clean(v, n)
            if Security and Security.V and Security.V.sanitizeString then return Security.V.sanitizeString(v, n) end
            return (type(v) == 'string' and v:sub(1, n)) or ''
        end
        reason, issuedBy = clean(reason, 255), clean(issuedBy, 64)
        local CH = Constants.FineChannel
        local impl = targetSrc and Bridge.Billing.Get() or nil
        if impl and impl.SupportsFines == false then impl = nil end
        local channel = impl and CH.INVOICE or CH.INTERNAL
        local fineId = MySQL.insert.await(
            'INSERT INTO mdp_fines (plate, owner, amount, reason, issued_by, channel) VALUES (?, ?, ?, ?, ?, ?)',
            { plate, owner, amount, reason, issuedBy, channel })
        if not fineId then return nil end
        if channel == CH.INTERNAL then return fineId, channel end

        local ok, res = Bridge.SafeCall(impl, 'SendBill', officerSrc, targetSrc, amount, reason, society, { fineId = fineId })
        local hasInvoice = BillingCommon and BillingCommon.HasInvoice and BillingCommon.HasInvoice(fineId) or false
        if ok and res == true then
            if hasInvoice then return fineId, CH.INVOICE end
            MySQL.update.await('UPDATE mdp_fines SET channel = ? WHERE id = ? AND paid = ?',
                { CH.NEEDS_REVIEW, fineId, Constants.FineStatus.UNPAID })
            print(('^3[mdp_garages] fine #%d: bill sent but no invoice linked -> needs_review^0'):format(fineId))
            return fineId, CH.NEEDS_REVIEW
        end
        -- SendBill failed: back to internal only if no invoice got linked anyway
        if not hasInvoice then
            MySQL.update.await('UPDATE mdp_fines SET channel = ? WHERE id = ? AND paid = ?',
                { CH.INTERNAL, fineId, Constants.FineStatus.UNPAID })
            return fineId, CH.INTERNAL
        end
        return fineId, CH.INVOICE
    end

    --- True if this fine is linked to an external invoice. Delegates to BillingCommon.HasInvoice (Integrations).
    function Bridge.Billing.IsExternalInvoice(fineId)
        if BillingCommon and BillingCommon.HasInvoice then return BillingCommon.HasInvoice(fineId) end
        local ok, r = pcall(MySQL.scalar.await, 'SELECT 1 FROM mdp_fine_invoices WHERE fine_id = ? LIMIT 1', { fineId })
        return ok and r ~= nil
    end
end
