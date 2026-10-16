-- Shared helpers for billing adapters (Integrations). Server only.
-- Maps provider invoice ids -> mdp_fines.id so paid hooks can recover fineId.
if not Bridge.IsServer then return end
BillingCommon = {}

-- Table mdp_fine_invoices (fine_id INT UNSIGNED -> mdp_fines.id) is created by sql/install.sql.

function BillingCommon.Link(provider, invoiceId, meta)
    if not invoiceId or not meta or math.type(meta.fineId) ~= 'integer' or meta.fineId <= 0 then return end
    pcall(MySQL.insert.await, 'INSERT IGNORE INTO mdp_fine_invoices (provider, invoice_id, fine_id) VALUES (?, ?, ?)',
        { provider, tostring(invoiceId), meta.fineId })
end

function BillingCommon.OnPaid(provider, invoiceId, src)
    local ok, fineId = pcall(MySQL.scalar.await, 'SELECT fine_id FROM mdp_fine_invoices WHERE provider = ? AND invoice_id = ?',
        { provider, tostring(invoiceId) })
    if ok and fineId and Bridge.Billing and Bridge.Billing.MarkFinePaid then
        return Bridge.Billing.MarkFinePaid(math.tointeger(fineId), src)
    end
    return false
end
