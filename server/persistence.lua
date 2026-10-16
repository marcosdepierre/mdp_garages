-- Restart / reconnect handling. Never depends on in-memory state from a previous run:
-- on start, live entities of ours (state bag 'mdp_plate') are saved + deleted, then every state 0 (OUT)
-- row is converted atomically per Config.OnRestartOutVehicles. Spawn registry and locks start empty and are
-- rebuilt from the DB by the spawner (state 2 rows -> proximity spawn).
local VS = Constants.VehicleState
local RES = GetCurrentResourceName()

local function saveEntityCoords(veh, plate)
    local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
    if not MDP.Props.ValidCoords(c) then return end -- L4
    MySQL.update.await('UPDATE mdp_vehicles SET coords = ?, heading = ? WHERE plate = ? AND state = ?',
        { json.encode({ x = c.x, y = c.y, z = c.z }), h, plate, VS.OUT })
end

--- Iterate live server vehicles that belong to this resource.
local function forEachOwnEntity(fn)
    for _, veh in ipairs(GetAllVehicles()) do
        local plate = Entity(veh).state.mdp_plate
        -- N10: the mdp_plate bag can be forged by the entity owner; require Security's server-side mark too
        plate = plate and Utils.NormalizePlate(plate)
        if plate and Security.IsServerEntity(veh, plate) then fn(veh, plate) end
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
    -- v3: existing rows default to 'mdp' (never auto-removed); only rows imported after v3 are 'framework'
    { 'mdp_vehicles', 'source', "ALTER TABLE `mdp_vehicles` ADD COLUMN `source` VARCHAR(16) NOT NULL DEFAULT 'mdp' AFTER `body`" },
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
    -- R3-6: UNIQUE(owner, config_id) on upgraded DBs (fill legacy '' values first so the index can be created)
    if hasTable('mdp_private_garages') and MySQL.scalar.await([[SELECT 1 FROM information_schema.statistics
        WHERE table_schema = DATABASE() AND table_name = 'mdp_private_garages' AND index_name = 'uq_mdp_pgarages_owner_config' LIMIT 1]]) == nil then
        MySQL.update.await("UPDATE `mdp_private_garages` SET `config_id` = CONCAT('legacy_', `id`) WHERE `config_id` = ''")
        MySQL.query.await('CREATE UNIQUE INDEX `uq_mdp_pgarages_owner_config` ON `mdp_private_garages` (`owner`, `config_id`)')
        print('[mdp_garages] schema upgrade: added UNIQUE(owner, config_id) on mdp_private_garages')
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
    -- v4 (R3b-1): fines must survive vehicle removal -> drop the old FK mdp_fines -> mdp_vehicles if present
    local fk = MySQL.scalar.await([[SELECT CONSTRAINT_NAME FROM information_schema.REFERENTIAL_CONSTRAINTS
        WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = 'mdp_fines' AND REFERENCED_TABLE_NAME = 'mdp_vehicles' LIMIT 1]])
    if fk and tostring(fk):match('^[%w_]+$') then
        MySQL.query.await(('ALTER TABLE `mdp_fines` DROP FOREIGN KEY `%s`'):format(fk))
        print('[mdp_garages] schema upgrade v4: dropped FK ' .. fk .. ' (fines no longer cascade with vehicles)')
    end
    MySQL.insert.await('INSERT IGNORE INTO mdp_schema_version (version) VALUES (1), (2), (3), (4)')
end

local function onStart()
    if not hasTable('mdp_vehicles') then
        error('table mdp_vehicles not found: run sql/install.sql on this database first', 0)
    end
    upgradeSchema() -- errors abort this attempt (MDP.Ready stays false)
    -- 1+2) OUT / world-parked reconciliation with live entities (R4-1, R4-2). Nothing from a previous run's memory:
    --   a) live entity with the row's normalized plate AND matching model (tagged by us or not, e.g. a dealership car
    --      after `restart mdp_garages`) -> ADOPT: state bag mdp_plate + TrackSpawn (owner src nil until ClaimSpawn).
    --        state 0 + OnRestartOutVehicles='garage' -> save health, GARAGED in DefaultGarage, entity deleted
    --        state 0 + 'park' + empty            -> PARKED_WORLD at the entity's CURRENT position (entity stays)
    --        state 0 + 'park' + occupied         -> stays OUT, tracked
    --        state 2                             -> stays PARKED_WORLD, tracked
    --   b) no live entity: state 0 -> GARAGED in DefaultGarage (both modes; a car without entity would be stuck)
    --                      state 2 -> unchanged (takeOut safety net spawns it)
    --   c) our tagged entities (mdp_plate) whose row is not 0/2 -> orphan, deleted
    local world = Utils.WorldVehiclesByPlate()
    local rows = MySQL.query.await('SELECT plate, model, state, coords FROM mdp_vehicles WHERE state IN (?, ?)', { VS.OUT, VS.PARKED_WORLD }) or {}
    local wanted, dupPlates, keepOut, adopted, parked, garaged = {}, {}, {}, 0, 0, 0
    local mode = Config.OnRestartOutVehicles or 'park'
    for _, r in ipairs(rows) do
        local plate, st = r.plate, tonumber(r.state)
        -- R5-3: adopt only if exactly ONE live entity matches plate AND model; duplicates -> adopt none, keep them
        local ent, matches = Utils.UniqueWorldVehicle(world, plate, Utils.ModelHash(r.model))
        if matches > 1 then
            dupPlates[plate] = true
            print(('^3[mdp_garages] restart: %d world entities match %s (plate+model); none adopted, duplicates left untouched^0'):format(matches, plate))
        end
        if ent then
            -- N1: Security.CanAdopt (server-marked entity, model, empty, within tolerance of DB coords).
            -- An OUT row's own server entity is adopted even if occupied/moved (driven across the restart);
            -- anything else that fails: empty -> deleted + logged, occupied -> ignored + logged.
            local okC, dc = pcall(json.decode, r.coords or '')
            local dbCoords = (okC and type(dc) == 'table' and tonumber(dc.x)) and vec3(dc.x, dc.y, dc.z) or nil
            local can, why = Security.CanAdopt(ent, plate, dbCoords, Utils.ModelHash(r.model))
            -- accepted exception: (a) state OUT, (b) IsServerEntity, (c) model already matched (CanAdopt checks model before
            -- occupied/moved), (d) tracked with owner nil, no ClaimSpawn to the driver (N4), (f) later saves validate coords (L4)
            if not can and st == VS.OUT and (why == 'occupied' or why == 'moved') and Security.IsServerEntity(ent, plate)
                and Utils.SameModel(GetEntityModel(ent), Utils.ModelHash(r.model)) then
                print(('^3[mdp_garages] restart: %s adopted despite %s (own server entity, state OUT)^0'):format(plate, why)) -- (e)
                can = true
            end
            if not can then
                if Utils.IsVehicleEmpty(ent) then
                    print(('^3[mdp_garages] restart: entity for %s not adoptable (%s), deleted^0'):format(plate, tostring(why)))
                    DeleteEntity(ent)
                else
                    print(('^3[mdp_garages] restart: entity for %s not adoptable (%s) and occupied, ignored; row kept OUT^0'):format(plate, tostring(why)))
                    dupPlates[plate] = true -- never treated as orphan
                    keepOut[plate] = true   -- P1R3-H1: never GARAGED while an occupied matching entity exists
                end
                ent = nil
            end
        end
        if ent then
            wanted[plate] = true
            Entity(ent).state:set('mdp_plate', plate, true)
            Security.TrackSpawn(plate, NetworkGetNetworkIdFromEntity(ent), nil)
            adopted = adopted + 1
            if st == VS.OUT then
                local c, h = GetEntityCoords(ent), GetEntityHeading(ent)
                -- R5-2: 'garage' never deletes an occupied vehicle -> falls back to the 'park' logic
                if mode == 'garage' and Utils.IsVehicleEmpty(ent) then
                    local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ?, engine = ?, body = ?, coords = NULL WHERE plate = ? AND state = ?',
                        { VS.GARAGED, Config.DefaultGarage, MDP.Props.Health('engine', GetVehicleEngineHealth(ent)), MDP.Props.Health('body', GetVehicleBodyHealth(ent)), plate, VS.OUT })
                    if n == 1 then Security.UntrackSpawn(plate); DeleteEntity(ent); wanted[plate] = nil; garaged = garaged + 1 end
                elseif Utils.IsVehicleEmpty(ent) and MDP.Props.ValidCoords(c) then
                    local n = MySQL.update.await([[UPDATE mdp_vehicles SET state = ?, coords = ?, heading = ?, parked_at = CURRENT_TIMESTAMP
                        WHERE plate = ? AND state = ?]], { VS.PARKED_WORLD, json.encode({ x = c.x, y = c.y, z = c.z }), h, plate, VS.OUT })
                    if n == 1 then parked = parked + 1 end
                end
            end
        elseif st == VS.OUT and keepOut[plate] then
            -- P1R3-H1: occupied unmarked entity (pre-a8fda43 spawn, dealership…) -> stays OUT, owner stores it normally
        elseif st == VS.OUT and matches > 1 then
            -- R6-1: ambiguous duplicates in the world -> keep OUT (never GARAGED, which would allow a third copy)
            print(('^3[mdp_garages] restart: %s kept OUT (ambiguous world duplicates, needs review)^0'):format(plate))
        elseif st == VS.OUT then
            local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ?, coords = NULL WHERE plate = ? AND state = ?',
                { VS.GARAGED, Config.DefaultGarage, plate, VS.OUT })
            if n == 1 then garaged = garaged + 1 end
        end
    end
    local orphans = 0
    forEachOwnEntity(function(veh, plate)
        if not wanted[plate] and not dupPlates[plate] and Utils.IsVehicleEmpty(veh) then DeleteEntity(veh); orphans = orphans + 1 end
    end)
    print(('[mdp_garages] restart recovery: %d entities adopted, %d OUT -> parked_world, %d OUT -> %s, %d orphan entities removed')
        :format(adopted, parked, garaged, Config.DefaultGarage, orphans))
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
    pcall(MDP.Streamer.Refresh)
    print('[mdp_garages] ready')
    CreateThread(function() MDP.Vehicles.SyncConnectedPlayers() end)
end

--- R3-5: startup recovery with retries (backoff 2 s / 5 s / 10 s), then a clear error and stay not_ready.
--- Console command `mdp_recover` re-runs it manually after fixing the cause.
local BACKOFF = { 2000, 5000, 10000 }
local recovering = false
function MDP.RunRecovery(by)
    if recovering or MDP.Ready then return end
    recovering = true
    local ok, err = pcall(onStart)
    local attempt = 0
    while not ok and attempt < #BACKOFF do
        attempt = attempt + 1
        print(('^3[mdp_garages] startup recovery failed (%s), retry %d/%d in %d s: %s^0')
            :format(by, attempt, #BACKOFF, BACKOFF[attempt] // 1000, tostring(err)))
        Wait(BACKOFF[attempt])
        ok, err = pcall(onStart)
    end
    recovering = false
    if not ok then
        print('^1[mdp_garages] ============================================================^0')
        print('^1[mdp_garages] STARTUP RECOVERY FAILED: ' .. tostring(err) .. '^0')
        print('^1[mdp_garages] All garage callbacks answer not_ready. Fix the cause (run sql/install.sql,^0')
        print('^1[mdp_garages] check DB permissions for ALTER) and type `mdp_recover` in the console.^0')
        print('^1[mdp_garages] ============================================================^0')
    end
end

RegisterCommand('mdp_recover', function(src)
    if src ~= 0 then return end -- console only
    CreateThread(function() MDP.RunRecovery('console') end)
end, true)

CreateThread(function()
    MySQL.ready(function() MDP.RunRecovery('startup') end)
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
local function healthOf(veh) -- M4
    return MDP.Props.Health('engine', GetVehicleEngineHealth(veh)), MDP.Props.Health('body', GetVehicleBodyHealth(veh))
end

local function toGarage(plate, veh)
    if not Utils.IsVehicleEmpty(veh) then return false end -- R5-2: never delete with someone inside
    local engine, body = healthOf(veh)
    local n = MySQL.update.await([[UPDATE mdp_vehicles SET state = ?, garage_id = ?, engine = ?, body = ?, coords = NULL, parked_at = NULL
        WHERE plate = ? AND state IN (?, ?)]], { VS.GARAGED, Config.DefaultGarage, engine, body, plate, VS.OUT, VS.PARKED_WORLD })
    if n == 1 then Security.UntrackSpawn(plate); DeleteEntity(veh) end
    return n == 1
end

local function applyPolicy(plate, veh, mode, droppedPed)
    local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
    local engine, body = healthOf(veh)
    if mode == 'keep' and not MDP.Props.ValidCoords(c) then mode = 'garage' end -- L4: never park at NaN/out-of-map coords
    -- R5-2: never delete a vehicle with someone (other than the dropping player) inside -> 'keep'/park logic
    if (mode == 'garage' or mode == 'impound') and not Utils.IsVehicleEmpty(veh, droppedPed) then
        print(('^3[mdp_garages] disconnect policy %s for %s: vehicle occupied, parking it instead^0'):format(mode, plate))
        mode = 'keep'
    end
    if mode == 'garage' then
        toGarage(plate, veh)
    elseif mode == 'impound' then
        local reason = (Config.ImpoundReasons or {})[Config.DisconnectImpoundReason] or { label = 'Abandoned', fee = 0, hours = 0 }
        local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ?, engine = ?, body = ?, coords = NULL, parked_at = NULL WHERE plate = ? AND state = ?',
            { VS.IMPOUNDED, Config.DefaultImpound, engine, body, plate, VS.OUT })
        if n == 1 then
            local impoundId = MySQL.insert.await([[INSERT INTO mdp_impound (plate, reason, officer, fee, release_after, location)
                VALUES (?, ?, 'system:disconnect', ?, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? HOUR), ?)]],
                { plate, reason.label, math.tointeger(reason.fee) or 0, math.tointeger(reason.hours) or 0, Config.DefaultImpound })
            Security.UntrackSpawn(plate); DeleteEntity(veh)
            MDP.Props.Hook(Bridge.FrameworkSync, 'OnImpound', plate, impoundId)
        end
    else -- keep: parked in place, stays tracked (owner nil) until the owner reconnects (ClaimSpawn)
        MySQL.update.await([[UPDATE mdp_vehicles SET state = ?, coords = ?, heading = ?, engine = ?, body = ?,
            parked_at = CURRENT_TIMESTAMP WHERE plate = ? AND state = ?]],
            { VS.PARKED_WORLD, json.encode({ x = c.x, y = c.y, z = c.z }), h, engine, body, plate, VS.OUT })
        MDP.Streamer.Track(plate)
    end
end

--- Runs the policy under the plate lock; if the lock is busy (e.g. a takeOut in progress) log and retry (R3-7).
function MDP.ApplyDisconnectPolicy(plate, veh, mode, attempt, droppedPed)
    local ok, r1, r2 = pcall(Security.WithLock, plate, 0, applyPolicy, plate, veh, mode, droppedPed)
    if not ok then
        print(('^1[mdp_garages] disconnect policy failed for %s: %s^0'):format(plate, tostring(r1)))
    elseif r1 == false and r2 == 'locked' then
        if attempt >= 5 then
            print(('^1[mdp_garages] disconnect policy for %s gave up: plate stayed locked^0'):format(plate))
            return
        end
        print(('^3[mdp_garages] disconnect policy for %s: plate locked, retry %d in 2 s^0'):format(plate, attempt))
        SetTimeout(2000, function()
            if DoesEntityExist(veh) then MDP.ApplyDisconnectPolicy(plate, veh, mode, attempt + 1, droppedPed) end
        end)
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
            if wasDriving then MDP.ApplyDisconnectPolicy(plate, veh, mode, 1, ped) end
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
