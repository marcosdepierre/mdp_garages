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

local function upgradeSchema()
    -- v2: mdp_vehicles.vtype (idempotent: only ALTER when the column is missing)
    local has = MySQL.scalar.await([[SELECT 1 FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = 'mdp_vehicles' AND column_name = 'vtype' LIMIT 1]])
    if not has then
        MySQL.query.await([[ALTER TABLE `mdp_vehicles` ADD COLUMN `vtype` VARCHAR(16) NOT NULL DEFAULT 'automobile' AFTER `model`]])
        print('[mdp_garages] schema upgraded to v2 (mdp_vehicles.vtype)')
    end
    MySQL.insert.await('INSERT IGNORE INTO mdp_schema_version (version) VALUES (2)')
end

local function onStart()
    local okUp, errUp = pcall(upgradeSchema)
    if not okUp then print('^1[mdp_garages] schema upgrade v2 failed: ' .. tostring(errUp) .. '^0') end
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
    -- 3) Interrupted fine payments (paid=2 'claiming') go back to unpaid.
    local reset = MySQL.update.await('UPDATE mdp_fines SET paid = 0 WHERE paid = 2') or 0
    if reset > 0 then print(('[mdp_garages] reset %d interrupted fine claims'):format(reset)) end
    -- 4) Schema version check (informative).
    local ok, v = pcall(MySQL.scalar.await, 'SELECT MAX(version) FROM mdp_schema_version')
    if not ok or (tonumber(v) or 0) < Constants.SchemaVersion then
        print(('^1[mdp_garages] database schema version %s < %d: run sql/install.sql^0'):format(tostring(ok and v or 'missing'), Constants.SchemaVersion))
    end
end

CreateThread(function()
    MySQL.ready(function() local ok, err = pcall(onStart); if not ok then print('^1[mdp_garages] restart recovery failed: ' .. tostring(err) .. '^0') end end)
end)

-- On stop: persist positions of live vehicles (they stay OUT; next start converts them).
AddEventHandler('onResourceStop', function(res)
    if res ~= RES then return end
    forEachOwnEntity(function(veh, plate) pcall(saveEntityCoords, veh, plate) end)
end)

---------------------------------------------------------------------------
-- Disconnect policy (Config.OnDisconnect): only for a tracked vehicle the player was DRIVING.
---------------------------------------------------------------------------
local function onDropped(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    local plate = Entity(veh).state.mdp_plate
    plate = plate and Utils.NormalizePlate(plate)
    if not plate or not Security.GetSpawnedEntity(plate) then return end
    local mode = Config.OnDisconnect or 'keep'
    local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
    local engine, body = GetVehicleEngineHealth(veh), GetVehicleBodyHealth(veh)
    pcall(Security.WithLock, plate, src, function()
        if mode == 'garage' then
            local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ?, engine = ?, body = ?, coords = NULL, parked_at = NULL WHERE plate = ? AND state = ?',
                { VS.GARAGED, Config.DefaultGarage, engine, body, plate, VS.OUT })
            if n == 1 then Security.UntrackSpawn(plate); DeleteEntity(veh) end
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
        else -- keep: stays in the world as parked
            MySQL.update.await([[UPDATE mdp_vehicles SET state = ?, coords = ?, heading = ?, engine = ?, body = ?,
                parked_at = CURRENT_TIMESTAMP WHERE plate = ? AND state = ?]],
                { VS.PARKED_WORLD, json.encode({ x = c.x, y = c.y, z = c.z }), h, engine, body, plate, VS.OUT })
        end
    end)
end

AddEventHandler('playerDropped', function()
    local src = source
    local ok, err = pcall(onDropped, src)
    if not ok then print('^1[mdp_garages] disconnect policy failed: ' .. tostring(err) .. '^0') end
end)
