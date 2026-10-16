-- Fine payment fallback: lib.callback mdp_garages:payFine + /mdp_payfine <id>.
-- Amount ALWAYS read from DB; client only sends fineId. Only channel='internal' fines without a linked invoice.
-- Claim 0->2 CHARGING (affectedRows==1) before charging; 2->1 on success, 2->0 on charge failure.
-- Rows left in CHARGING after a crash are moved to channel needs_review on start (never reset: money may be taken).
-- Error codes are the documented ones (Constants.ErrorCodes); text comes from locale ui.err_<code>.
local function errText(code) return Utils.ErrorText(code) end

local function payFine(src, fineId)
    fineId = math.tointeger(tonumber(fineId) or -1)
    if not fineId or fineId <= 0 then return { ok = false, error = 'invalid_request' } end
    local ident = Bridge.GetIdentifier(src)
    if not ident then return { ok = false, error = 'invalid_source' } end
    local row = MySQL.single.await('SELECT amount, channel FROM mdp_fines WHERE id = ? AND owner = ? AND paid = 0', { fineId, ident })
    if not row then return { ok = false, error = 'fine_not_found' } end
    if row.channel ~= 'internal' or Bridge.Billing.IsExternalInvoice(fineId) then return { ok = false, error = 'external_invoice' } end
    local amount = math.tointeger(row.amount)
    if not amount or not Bridge.ValidAmount(amount) then return { ok = false, error = 'invalid_amount' } end
    local charged = false -- M5: once money is taken, never release the claim on error
    local ok, res = pcall(Security.WithLock, 'fine:' .. fineId, src, function()
        -- claim (0 -> 2) before touching money; only one caller can win
        local claimed = MySQL.update.await(
            "UPDATE mdp_fines SET paid = 2 /* CHARGING */ WHERE id = ? AND owner = ? AND paid = 0 AND channel = 'internal'", { fineId, ident })
        if claimed ~= 1 then return { ok = false, error = 'already_paid' } end
        if not Bridge.RemoveMoney(src, 'bank', amount, 'mdp_garages fine #' .. fineId) then
            MySQL.update.await('UPDATE mdp_fines SET paid = 0 WHERE id = ? AND paid = 2', { fineId })
            return { ok = false, error = 'insufficient_funds' }
        end
        charged = true
        MySQL.update.await('UPDATE mdp_fines SET paid = 1 WHERE id = ? AND paid = 2', { fineId })
        TriggerEvent('mdp_garages:server:finePaid', fineId, src)
        return { ok = true, data = { fineId = fineId, amount = amount } }
    end)
    if not ok then
        if charged then
            -- money already taken: leave CHARGING; startup recovery moves it to needs_review (/mdp_finereview)
            print(('^1[mdp_garages] fine #%d: error after charging (%s), left CHARGING for review^0'):format(fineId, tostring(res)))
        else
            -- error before charging: release a possible claim
            pcall(MySQL.update.await, 'UPDATE mdp_fines SET paid = 0 WHERE id = ? AND paid = 2', { fineId })
        end
        return { ok = false, error = 'server_error' }
    end
    if type(res) ~= 'table' then return { ok = false, error = 'locked' } end
    return res
end

MDP.Callback('mdp_garages:payFine', {
    rateLimit = { max = 2, windowMs = 2000 },
    schema = { fineId = Security.Int(1, 4294967295) },
}, function(src, data) return payFine(src, data.fineId) end)

RegisterCommand('mdp_payfine', function(src, args)
    if src == 0 then return end
    if not Security.RateLimit(src, 'cmd:payfine', 2, 2000) then return end
    if not MDP.Ready then return Bridge.Notify(src, Utils.ErrorText('not_ready'), 'error') end
    local res = payFine(src, args[1])
    if res.ok then
        Bridge.Notify(src, _L('fine_paid', res.data.amount), 'success')
    else
        Bridge.Notify(src, _L('fine_pay_failed', errText(res.error)), 'error')
    end
end, false)
