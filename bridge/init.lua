-- Framework autodetection. qbx_core is checked FIRST because Qbox also exposes qb-core compatibility.
Bridge = Bridge or {}
Bridge.IsServer = IsDuplicityVersion()

local function started(res)
    local s = GetResourceState(res)
    return s == 'started' or s == 'starting'
end

local FRAMEWORK_RESOURCE = { qbx = 'qbx_core', qb = 'qb-core', esx = 'es_extended' }

local function autodetect()
    if started('qbx_core') then return 'qbx' end
    if started('qb-core') then return 'qb' end
    if started('es_extended') then return 'esx' end
    return 'standalone'
end

local function detect()
    local forced = Config and Config.Framework
    forced = type(forced) == 'string' and forced:lower() or 'auto'
    if forced == 'auto' then return autodetect() end
    if forced == 'standalone' then return 'standalone' end
    local res = FRAMEWORK_RESOURCE[forced]
    if not res then
        print(('^1[mdp_garages] invalid Config.Framework "%s" (use auto|qbx|qb|esx|standalone), falling back to auto^0')
            :format(tostring(Config.Framework)))
        return autodetect()
    end
    if not started(res) then
        print(('^1[mdp_garages] Config.Framework = "%s" but %s is not started (ensure it before mdp_garages), falling back to auto^0')
            :format(forced, res))
        return autodetect()
    end
    return forced
end

Bridge.Framework = detect()
-- ox_lib is a hard dependency (fxmanifest), no runtime check needed.
Bridge.IsStarted = started

-- Integration adapter registry (fuel/keys/billing/notify/phone).
-- Adapter files (written by Integrations, see docs/integrations.md) call:
--   Bridge.RegisterAdapter('fuel', 'ox_fuel', { GetFuel = fn, SetFuel = fn, ... })
-- Order of file loading does not matter; resolution happens lazily at call time.
Bridge.Adapters = { fuel = {}, keys = {}, billing = {}, notify = {}, phone = {} }
function Bridge.RegisterAdapter(kind, resource, impl)
    Bridge.Adapters[kind] = Bridge.Adapters[kind] or {}
    Bridge.Adapters[kind][resource] = impl
end

-- Pick adapter: Config.<Kind> = 'auto' -> first registered adapter whose resource is started
-- (in the given priority list), or an explicit resource name.
function Bridge.ResolveAdapter(kind, setting, priority)
    local list = Bridge.Adapters[kind] or {}
    if setting and setting ~= 'auto' then
        return (list[setting] and started(setting)) and list[setting] or nil, setting
    end
    for _, res in ipairs(priority or {}) do
        if list[res] and started(res) then return list[res], res end
    end
    for res, impl in pairs(list) do
        if started(res) then return impl, res end
    end
    return nil
end

-- Safe call: returns ok, result; never throws
function Bridge.SafeCall(impl, fnName, ...)
    if not impl or type(impl[fnName]) ~= 'function' then return false end
    local ok, res = pcall(impl[fnName], ...)
    if not ok and Config.Debug then print('^3[mdp_garages] adapter error: ' .. tostring(res) .. '^0') end
    return ok, res
end

if Bridge.Framework == 'standalone' then
    print('^1' .. _L('standalone_warning') .. '^0')
else
    print('^2' .. _L('framework_detected', Bridge.Framework) .. '^0')
end

-- Shared sanity helper for money amounts
function Bridge.ValidAmount(amount)
    return type(amount) == 'number' and amount == amount and amount > 0
        and amount <= (Config.MaxMoneyAmount or 1e9) and math.floor(amount) == amount
end

-- Standalone defaults (overridden by framework files when matched)
if Bridge.IsServer then
    function Bridge.GetPlayer(src) return GetPlayerName(src) and { source = src } or nil end
    function Bridge.GetIdentifier(src)
        return GetPlayerIdentifierByType and GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifier(src, 0)
    end
    function Bridge.GetJob(src) return { name = 'unemployed', grade = 0, onduty = false, onDuty = false } end
    function Bridge.GetMoney(src, account) return 0 end
    function Bridge.RemoveMoney(src, account, amount, reason)
        if not Bridge.ValidAmount(amount) then return false end
        return false -- no economy in standalone
    end
    function Bridge.FrameworkNotify(src, msg, ntype)
        TriggerClientEvent('mdp_garages:client:notify', src, msg, ntype)
    end
else
    function Bridge.FrameworkNotify(msg, ntype)
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(tostring(msg))
        EndTextCommandThefeedPostTicker(false, true)
    end
    function Bridge.GetPlayerData() return {} end
    RegisterNetEvent('mdp_garages:client:notify', function(msg, ntype) Bridge.FrameworkNotify(msg, ntype) end)
end
