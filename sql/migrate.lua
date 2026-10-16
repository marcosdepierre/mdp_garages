-- mdp_garages optional migration: framework tables -> mdp_vehicles.
-- Never modifies originals (SELECT + INSERT IGNORE). Opt-in:
--   Config.Migration.Enabled = true  -> runs once on resource start
--   or console / admin (ace) command: mdp_migrate
local function tableExists(name)
    return MySQL.scalar.await(
        'SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ? LIMIT 1', { name }) ~= nil
end

local function columnExists(tbl, col)
    return MySQL.scalar.await(
        'SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ? LIMIT 1',
        { tbl, col }) ~= nil
end

local function insert(plate, owner, model, props, state, garage, fuel, engine, body)
    plate = Utils.NormalizePlate(plate)
    if not Utils.IsValidPlate(plate) or not owner then return 0 end
    local r = MySQL.insert.await([[INSERT IGNORE INTO mdp_vehicles
        (plate, owner, model, props, state, garage_id, fuel, engine, body)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        { plate, owner, tostring(model or 'unknown'), props, state, garage, fuel or 100, engine or 1000, body or 1000 })
    return (r and r > 0) and 1 or 0
end

local function migrateESX()
    if not tableExists('owned_vehicles') then return 0, 0 end
    local rows = MySQL.query.await('SELECT owner, plate, vehicle FROM owned_vehicles') or {}
    local n = 0
    for _, r in ipairs(rows) do
        local ok, props = pcall(json.decode, r.vehicle or '{}')
        local model = ok and type(props) == 'table' and props.model or nil
        n = n + insert(r.plate, r.owner, model, r.vehicle, VehicleState.GARAGED, Config.DefaultGarage)
    end
    return #rows, n
end

local function migrateQB()
    if not tableExists('player_vehicles') then return 0, 0 end
    local hasState = columnExists('player_vehicles', 'state')
    local rows = MySQL.query.await(('SELECT citizenid, plate, vehicle, mods, garage, fuel, engine, body%s FROM player_vehicles')
        :format(hasState and ', state' or '')) or {}
    local n = 0
    for _, r in ipairs(rows) do
        -- QB state: 0 out, 1 garaged, 2 impounded -> ours
        local st = VehicleState.GARAGED
        if r.state == 2 then st = VehicleState.IMPOUNDED end
        local gid = r.garage and ('public:' .. tostring(r.garage)) or nil
        gid = Utils.ResolveGarageId(gid, r.plate)
        n = n + insert(r.plate, r.citizenid, r.vehicle, r.mods, st, gid, r.fuel, r.engine, r.body)
    end
    return #rows, n
end

local function run(by)
    local eT, eI = migrateESX()
    local qT, qI = migrateQB()
    print(('[mdp_garages] migration by %s: owned_vehicles %d read / %d imported, player_vehicles %d read / %d imported (duplicates skipped)')
        :format(by, eT, eI, qT, qI))
end

-- restricted = true -> only console or players with the ace permission
RegisterCommand('mdp_migrate', function(src)
    if src ~= 0 and not IsPlayerAceAllowed(src, Config.Migration.Ace) then return end
    CreateThread(function() run(src == 0 and 'console' or ('player ' .. src)) end)
end, true)

if Config.Migration and Config.Migration.Enabled then
    CreateThread(function() Wait(2000); run('auto (Config.Migration.Enabled)') end)
end
