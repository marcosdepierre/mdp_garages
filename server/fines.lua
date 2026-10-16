-- Fine payment fallback: lib.callback mdp_garages:payFine + /mdp_payfine <id>.
-- Amount ALWAYS read from DB; client only sends fineId. Idempotent: paid flipped (affectedRows==1) BEFORE charging,
-- rolled back if the charge fails. Fines sent as external invoices are refused ('external_invoice').
local ERROR_KEYS = {
    invalid_request = 'err_invalid_request', invalid_source = 'err_invalid_request', not_found = 'err_fine_not_found',
    invalid_amount = 'err_invalid_request', insufficient_funds = 'not_enough_money', already_paid = 'err_already_paid',
    external_invoice = 'err_external_invoice', locked = 'err_busy', rate_limited = 'err_busy',
}

local function errText(code) return _L(ERROR_KEYS[code] or 'err_generic') end

local function payFine(src, fineId)
    fineId = math.tointeger(tonumber(fineId) or -1)
    if not fineId or fineId <= 0 then return { ok = false, error = 'invalid_request' } end
    local ident = Bridge.GetIdentifier(src)
    if not ident then return { ok = false, error = 'invalid_source' } end
    local row = MySQL.single.await('SELECT amount FROM mdp_fines WHERE id = ? AND owner = ? AND paid = 0', { fineId, ident })
    if not row then return { ok = false, error = 'not_found' } end
    if Bridge.Billing.IsExternalInvoice(fineId) then return { ok = false, error = 'external_invoice' } end
    local amount = math.tointeger(row.amount)
    if not amount or not Bridge.ValidAmount(amount) then return { ok = false, error = 'invalid_amount' } end
    local ok, res = pcall(Security.WithLock, 'fine:' .. fineId, src, function()
        if Bridge.GetMoney(src, 'bank') < amount then return { ok = false, error = 'insufficient_funds' } end
        local affected = MySQL.update.await('UPDATE mdp_fines SET paid = 1 WHERE id = ? AND owner = ? AND paid = 0', { fineId, ident })
        if affected ~= 1 then return { ok = false, error = 'already_paid' } end
        if not Bridge.RemoveMoney(src, 'bank', amount, 'mdp_garages fine #' .. fineId) then
            MySQL.update.await('UPDATE mdp_fines SET paid = 0 WHERE id = ? AND paid = 1', { fineId })
            return { ok = false, error = 'insufficient_funds' }
        end
        return { ok = true, data = { fineId = fineId, amount = amount } }
    end)
    if not ok then return { ok = false, error = 'server_error' } end
    if type(res) ~= 'table' then return { ok = false, error = 'locked' } end
    return res
end

Security.RegisterSecureCallback('mdp_garages:payFine', {
    rateLimit = { max = 2, windowMs = 2000 },
    schema = { fineId = Security.Int(1, 4294967295) },
}, function(src, data) return payFine(src, data.fineId) end)

RegisterCommand('mdp_payfine', function(src, args)
    if src == 0 then return end
    if not Security.RateLimit(src, 'cmd:payfine', 2, 2000) then return end
    local res = payFine(src, args[1])
    if res.ok then
        Bridge.Notify(src, _L('fine_paid', res.data.amount), 'success')
    else
        Bridge.Notify(src, _L('fine_pay_failed', errText(res.error)), 'error')
    end
end, false)
