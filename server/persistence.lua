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

local function onStart()
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
