-- Shared helpers for billing adapters (Integrations). Server only.
-- Maps provider invoice ids -> mdp_fines.id so paid hooks can recover fineId.
if not Bridge.IsServer then return end
BillingCommon = {}

-- Table mdp_fine_invoices (fine_id INT UNSIGNED -> mdp_fines.id) is created by sql/install.sql.

--- Links a provider invoice to mdp_fines.id. Returns true on success, false (and logs) on failure.
--- Callers (Bridge.Billing.IssueFine) mark the fine channel='needs_review' when this fails.
function BillingCommon.Link(provider, invoiceId, meta)
    if not meta or meta.fineId == nil then return true end -- not a fine (fee): nothing to link
    if invoiceId == nil or math.type(meta.fineId) ~= 'integer' or meta.fineId <= 0 then
        print(('^1[mdp_garages][billing] link inválido provider=%s invoice=%s fine=%s^0'):format(tostring(provider), tostring(invoiceId), tostring(meta.fineId)))
        return false
    end
    local ok, res = pcall(MySQL.insert.await, 'INSERT IGNORE INTO mdp_fine_invoices (provider, invoice_id, fine_id) VALUES (?, ?, ?)',
        { provider, tostring(invoiceId), meta.fineId })
    if not ok then
        print(('^1[mdp_garages][billing] fallo al enlazar factura provider=%s invoice=%s fine=%d: %s^0'):format(provider, tostring(invoiceId), meta.fineId, tostring(res)))
        return false
    end
    if not BillingCommon.HasInvoice(meta.fineId) then
        print(('^1[mdp_garages][billing] enlace no persistido provider=%s invoice=%s fine=%d^0'):format(provider, tostring(invoiceId), meta.fineId))
        return false
    end
    return true
end

--- True if the fine is linked to an external invoice (used to block double payment via /mdp_payfine).
function BillingCommon.HasInvoice(fineId)
    if math.type(fineId) ~= 'integer' or fineId <= 0 then return false end
    local ok, n = pcall(MySQL.scalar.await, 'SELECT 1 FROM mdp_fine_invoices WHERE fine_id = ? LIMIT 1', { fineId })
    return ok and n ~= nil
end

-- In-flight guard: a fineId is processed by at most one paid-hook call at a time; once
-- MarkFinePaid returned true the fineId is remembered so repeated provider events are no-ops.
local inFlight, done = {}, {}

--- Paid hook entry point. Resolves fineId ONLY via mdp_fine_invoices (never trusts event payload
--- amounts or ids beyond the provider invoice id). Calls MarkFinePaid at most once per fineId.
--- Never moves money. Returns true only if this call flipped the fine to paid.
function BillingCommon.OnPaid(provider, invoiceId, src)
    if type(provider) ~= 'string' or invoiceId == nil then return false end
    local ok, fineId = pcall(MySQL.scalar.await,
        'SELECT fine_id FROM mdp_fine_invoices WHERE provider = ? AND invoice_id = ?', { provider, tostring(invoiceId) })
    fineId = ok and math.tointeger(tonumber(fineId)) or nil
    if not fineId or fineId <= 0 then return false end
    if done[fineId] or inFlight[fineId] then return false end
    if not (Bridge.Billing and Bridge.Billing.MarkFinePaid) then return false end
    inFlight[fineId] = true
    local okCall, changed = pcall(Bridge.Billing.MarkFinePaid, fineId, src)
    inFlight[fineId] = nil
    if okCall and changed == true then done[fineId] = true return true end
    return false
end
