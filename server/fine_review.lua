-- /mdp_finereview <id> paid|void  (Integrations). Resolves fines left in channel='needs_review'
-- (invoice created by the billing resource but the mdp_fine_invoices link failed).
-- Permission: console, or ACE 'mdp_garages.admin'.
local FS = Constants.FineStatus   -- UNPAID=0, PAID=1, CLAIMING=2, VOIDED=3 (shared/constants.lua)
local CH = Constants.FineChannel  -- NEEDS_REVIEW='needs_review', INVOICE='invoice'
local ACE = 'mdp_garages.admin'

local function isAllowed(src)
    return src == 0 or IsPlayerAceAllowed(src, ACE)
end

local function reply(src, msg, ntype)
    if src == 0 then print('[mdp_garages][finereview] ' .. msg) else Bridge.Notify(src, msg, ntype) end
end

local function log(src, fineId, action, result)
    local who = src == 0 and 'console' or (('%s (%s)'):format(GetPlayerName(src) or '?', tostring(Bridge.GetIdentifier(src))))
    print(('[mdp_garages][finereview] %s fine=%d action=%s result=%s'):format(who, fineId, action, result))
end

--- VOID: single swap point (decided: paid = FineStatus.VOIDED, no extra column).
local function voidFine(fineId)
    return MySQL.update.await('UPDATE mdp_fines SET paid = ? WHERE id = ? AND paid = ? AND channel = ?',
        { FS.VOIDED, fineId, FS.UNPAID, CH.NEEDS_REVIEW }) == 1
end

local function markPaid(fineId, src)
    local row = MySQL.single.await('SELECT 1 AS x FROM mdp_fines WHERE id = ? AND paid = ? AND channel = ?',
        { fineId, FS.UNPAID, CH.NEEDS_REVIEW })
    if not row then return false end
    if Bridge.Billing.MarkFinePaid(fineId, src) ~= true then return false end
    -- paid via the external invoice: record the channel it actually went through
    MySQL.update.await('UPDATE mdp_fines SET channel = ? WHERE id = ? AND channel = ?', { CH.INVOICE, fineId, CH.NEEDS_REVIEW })
    return true
end

RegisterCommand('mdp_finereview', function(src, args)
    if not isAllowed(src) then
        if Security and Security.LogReject then Security.LogReject(src, 'mdp_finereview', 'no_permission') end
        return
    end
    if src ~= 0 and Security and Security.RateLimit and not Security.RateLimit(src, 'cmd:finereview', 3, 2000) then return end
    local fineId = math.tointeger(tonumber(args[1]))
    local action = type(args[2]) == 'string' and args[2]:lower() or nil
    if not fineId or fineId <= 0 or fineId > 4294967295 or (action ~= 'paid' and action ~= 'void') then
        return reply(src, 'Uso: /mdp_finereview <id> paid|void', 'error')
    end
    local ok, done = pcall(action == 'paid' and markPaid or voidFine, fineId, src)
    local result = (ok and done) and 'ok' or (ok and 'not_found_or_not_in_review' or ('error: ' .. tostring(done)))
    log(src, fineId, action, result)
    if ok and done then
        reply(src, ('Multa #%d %s'):format(fineId, action == 'paid' and 'marcada como pagada' or 'anulada'), 'success')
    else
        reply(src, ('Multa #%d: sin cambios (%s)'):format(fineId, result), 'error')
    end
end, false)
