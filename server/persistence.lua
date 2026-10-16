-- Restart / reconnect handling. Never depends on in-memory state from a previous run:
-- on start, live entities of ours (state bag 'mdp_plate') are saved + deleted, then every state 0 (OUT)
-- row is converted atomically per Config.OnRestartOutVehicles. Spawn registry and locks start empty and are
-- rebuilt from the DB by the spawner (state 2 rows -> proximity spawn).
local VS = Constants.VehicleState
local RES = GetCurrentResourceName()

local function saveEntityCoords(veh, plate)
    local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
    MySQL.update.await('UPDATE mdp_vehicles SET coords = ?, heading = ? WHERE plate = ? AND state = ?',
        { json.encode({ x = c.x, y = c.y, z = c.z }), h, plate, VS.OUT })
end

--- Iterate live server vehicles that belong to this resource.
local function forEachOwnEntity(fn)
    for _, veh in ipairs(GetAllVehicles()) do
        local plate = Entity(veh).state.mdp_plate
        if plate then fn(veh, Utils.NormalizePlate(plate)) end
    end
end

local function hasColumn(tbl, col)
    return MySQL.scalar.await([[SELECT 1 FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ? LIMIT 1]], { tbl, col }) ~= nil
end

local function hasTable(tbl)
    return MySQL.scalar.await([[SELECT 1 FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = ? LIMIT 1]], { tbl }) ~= nil
end

--- Idempotent upgrades for databases created by older commits (QA N9). Each step checks before altering.
local UPGRADES = {
    { 'mdp_vehicles', 'parked_at', "ALTER TABLE `mdp_vehicles` ADD COLUMN `parked_at` TIMESTAMP NULL DEFAULT NULL" },
    { 'mdp_vehicles', 'vtype', "ALTER TABLE `mdp_vehicles` ADD COLUMN `vtype` VARCHAR(16) NOT NULL DEFAULT 'automobile' AFTER `model`" },
    { 'mdp_fines', 'channel', "ALTER TABLE `mdp_fines` ADD COLUMN `channel` ENUM('internal','invoice','external','needs_review') NOT NULL DEFAULT 'internal'" },
    -- existing rows get '' ; UNIQUE(owner, config_id) is only created by install.sql on fresh installs
    { 'mdp_private_garages', 'config_id', "ALTER TABLE `mdp_private_garages` ADD COLUMN `config_id` VARCHAR(32) NOT NULL DEFAULT '' AFTER `owner`" },
}

local function upgradeSchema()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `mdp_schema_version` (
        `version` INT UNSIGNED NOT NULL, `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (`version`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
    for _, u in ipairs(UPGRADES) do
        if hasTable(u[1]) and not hasColumn(u[1], u[2]) then
            MySQL.query.await(u[3])
            print(('[mdp_garages] schema upgrade: added %s.%s'):format(u[1], u[2]))
        end
    end
    -- fines.channel ENUM on DBs that had it without needs_review
    local ctype = hasTable('mdp_fines') and MySQL.scalar.await([[SELECT COLUMN_TYPE FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = 'mdp_fines' AND column_name = 'channel']])
    if ctype and not tostring(ctype):find('needs_review', 1, true) then
        MySQL.query.await("ALTER TABLE `mdp_fines` MODIFY `channel` ENUM('internal','invoice','external','needs_review') NOT NULL DEFAULT 'internal'")
    end
    if hasTable('mdp_fines') and not hasTable('mdp_fine_invoices') then
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS `mdp_fine_invoices` (
            `provider` VARCHAR(32) NOT NULL, `invoice_id` VARCHAR(64) NOT NULL, `fine_id` INT UNSIGNED NOT NULL,
            PRIMARY KEY (`provider`, `invoice_id`), KEY `idx_mdp_fine_invoices_fine` (`fine_id`),
            CONSTRAINT `fk_mdp_fine_invoices_fine` FOREIGN KEY (`fine_id`) REFERENCES `mdp_fines` (`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        print('[mdp_garages] schema upgrade: created mdp_fine_invoices')
    end
    MySQL.insert.await('INSERT IGNORE INTO mdp_schema_version (version) VALUES (1), (2)')
end

local function onStart()
    upgradeSchema() -- errors abort startup (MDP.Ready stays false)
    -- 1) Leftover entities (resource restart without server restart): persist position, remove entity.
    local cleaned = 0
    forEachOwnEntity(function(veh, plate)
        pcall(saveEntityCoords, veh, plate)
        DeleteEntity(veh)
        cleaned = cleaned + 1
    end)
    -- 2) Atomic conversion of OUT rows.
    local parked, garaged = 0, 0
    if Config.OnRestartOutVehicles == 'park' then
        parked = MySQL.update.await(
            'UPDATE mdp_vehicles SET state = ?, parked_at = CURRENT_TIMESTAMP WHERE state = ? AND coords IS NOT NULL',
            { VS.PARKED_WORLD, VS.OUT }) or 0
    end
    garaged = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ? WHERE state = ?',
        { VS.GARAGED, Config.DefaultGarage, VS.OUT }) or 0
    print(('[mdp_garages] restart recovery: %d leftover entities removed, %d OUT -> parked_world, %d OUT -> %s')
        :format(cleaned, parked, garaged, Config.DefaultGarage))
    -- 3) Interrupted fine payments (paid=2 CHARGING): money may already have been taken, so never reset blindly.
    --    Move them to channel needs_review (paid=0) for an admin to resolve with /mdp_finereview <id> paid|void (QA N5).
    local FS = Constants.FineStatus
    local stuck = MySQL.query.await('SELECT id, owner, amount FROM mdp_fines WHERE paid = ?', { FS.CHARGING }) or {}
    for _, f in ipairs(stuck) do
        local n = MySQL.update.await('UPDATE mdp_fines SET paid = ?, channel = ? WHERE id = ? AND paid = ?',
            { FS.UNPAID, Constants.FineChannel.NEEDS_REVIEW, f.id, FS.CHARGING })
        if n == 1 then
            print(('^3[mdp_garages] fine #%d (%s, $%s) was interrupted while CHARGING -> needs_review; check the bank log and run /mdp_finereview %d paid|void^0')
                :format(f.id, tostring(f.owner), tostring(f.amount), f.id))
        end
    end
    -- 4) Schema version check (informative).
    local ok, v = pcall(MySQL.scalar.await, 'SELECT MAX(version) FROM mdp_schema_version')
    if not ok or (tonumber(v) or 0) < Constants.SchemaVersion then
        print(('^1[mdp_garages] database schema version %s < %d: run sql/install.sql^0'):format(tostring(ok and v or 'missing'), Constants.SchemaVersion))
    end
    -- 5) Accept callbacks only now (QA N4), then sync players already connected (resource restart, QA N7).
    MDP.Ready = true
    print('[mdp_garages] ready')
    CreateThread(function() MDP.Vehicles.SyncConnectedPlayers() end)
end

CreateThread(function()
    MySQL.ready(function()
        local ok, err = pcall(onStart)
        if not ok then
            print('^1[mdp_garages] startup recovery failed, callbacks stay disabled (not_ready): ' .. tostring(err) .. '^0')
        end
    end)
end)

-- On stop: persist positions of live vehicles (they stay OUT; next start converts them).
AddEventHandler('onResourceStop', function(res)
    if res ~= RES then return end
    forEachOwnEntity(function(veh, plate) pcall(saveEntityCoords, veh, plate) end)
end)

---------------------------------------------------------------------------
-- Disconnect policy (Config.OnDisconnect) via Security.OnPlayerDropped (server/security.lua owns playerDropped).
-- Security has already released the player's locks and kept their spawns tracked with owner = nil.
-- Applies to each tracked vehicle of the player that they were DRIVING (or, if the ped is already gone, that has no driver).
---------------------------------------------------------------------------
local function healthOf(veh) return GetVehicleEngineHealth(veh), GetVehicleBodyHealth(veh) end

local function toGarage(plate, veh)
    local engine, body = healthOf(veh)
    local n = MySQL.update.await([[UPDATE mdp_vehicles SET state = ?, garage_id = ?, engine = ?, body = ?, coords = NULL, parked_at = NULL
        WHERE plate = ? AND state IN (?, ?)]], { VS.GARAGED, Config.DefaultGarage, engine, body, plate, VS.OUT, VS.PARKED_WORLD })
    if n == 1 then Security.UntrackSpawn(plate); DeleteEntity(veh) end
    return n == 1
end

local function applyPolicy(plate, veh, mode)
    local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
    local engine, body = healthOf(veh)
    if mode == 'garage' then
        toGarage(plate, veh)
    elseif mode == 'impound' then
        local reason = (Config.ImpoundReasons or {})[Config.DisconnectImpoundReason] or { label = 'Abandoned', fee = 0, hours = 0 }
        local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ?, engine = ?, body = ?, coords = NULL, parked_at = NULL WHERE plate = ? AND state = ?',
            { VS.IMPOUNDED, Config.DefaultImpound, engine, body, plate, VS.OUT })
        if n == 1 then
            MySQL.insert.await([[INSERT INTO mdp_impound (plate, reason, officer, fee, release_after, location)
                VALUES (?, ?, 'system:disconnect', ?, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? HOUR), ?)]],
                { plate, reason.label, math.tointeger(reason.fee) or 0, math.tointeger(reason.hours) or 0, Config.DefaultImpound })
            Security.UntrackSpawn(plate); DeleteEntity(veh)
        end
    else -- keep: parked in place, stays tracked (owner nil) until the owner reconnects (ClaimSpawn)
        MySQL.update.await([[UPDATE mdp_vehicles SET state = ?, coords = ?, heading = ?, engine = ?, body = ?,
            parked_at = CURRENT_TIMESTAMP WHERE plate = ? AND state = ?]],
            { VS.PARKED_WORLD, json.encode({ x = c.x, y = c.y, z = c.z }), h, engine, body, plate, VS.OUT })
    end
end

function Security.OnPlayerDropped(src, identifier, plates, reason)
    if type(plates) ~= 'table' or #plates == 0 then return end
    local ped = GetPlayerPed(src)
    local mode = Config.OnDisconnect or 'keep'
    for _, plate in ipairs(plates) do
        local veh = Security.GetSpawnedEntity(plate)
        if veh then
            local driver = GetPedInVehicleSeat(veh, -1)
            local wasDriving = (ped and ped ~= 0 and driver == ped) or ((not ped or ped == 0) and (driver == 0 or not driver))
            if wasDriving then
                local ok, err = pcall(Security.WithLock, plate, 0, applyPolicy, plate, veh, mode)
                if not ok then print(('^1[mdp_garages] disconnect policy failed for %s: %s^0'):format(plate, tostring(err))) end
            end
        end
    end
end

--- Optional (Config.Security.despawnOnDropMs): unclaimed vehicle after the timeout -> save, then garage.
function Security.OnDroppedVehicleTimeout(plate, netId, identifier)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    local ok, err = pcall(Security.WithLock, plate, 0, toGarage, plate, veh)
    if not ok then print(('^1[mdp_garages] drop timeout failed for %s: %s^0'):format(plate, tostring(err))) end
end
