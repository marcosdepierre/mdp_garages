-- Phase 1: parked-vehicle streamer (state 2 PARKED_WORLD).
-- * Registry of state-2 rows (refreshed from DB every Config.StreamerRefreshMs and invalidated on transitions).
-- * Every Config.StreamerTickMs: nearest player distance per parked vehicle.
--     no entity and d <= WorldSpawnRadius                 -> spawn (WithLock + GetSpawnedEntity re-check + TrackSpawn)
--     entity, empty, and d > WorldSpawnRadius+DespawnMargin -> save coords/heading/health if changed, delete, untrack
--     entity with a driver                                 -> becomes OUT (0) for that driver (ClaimSpawn), leaves registry
-- * Single spawn owner: the server, keyed by plate (Security.TrackSpawn). Never two entities per plate.
MDP.Streamer = {}
local VS = Constants.VehicleState
local registry = {}      -- plate -> row { plate, model, vtype, props, fuel, engine, body, coords={x,y,z}, heading }
local lastRefresh = 0
local pending = {}       -- plate -> true while a spawn thread runs (spawns wait up to 3 s each)

local function decodeCoords(raw)
    local ok, c = pcall(json.decode, raw or '')
    if ok and type(c) == 'table' and tonumber(c.x) and tonumber(c.y) and tonumber(c.z) then return vec3(c.x, c.y, c.z) end
    return nil
end

function MDP.Streamer.Refresh()
    local rows = MySQL.query.await([[SELECT plate, model, vtype, props, fuel, engine, body, mileage, coords, heading
        FROM mdp_vehicles WHERE state = ? AND coords IS NOT NULL]], { VS.PARKED_WORLD }) or {}
    local fresh = {}
    for _, r in ipairs(rows) do
        local c = decodeCoords(r.coords)
        if c then r.pos = c; fresh[r.plate] = r end
    end
    registry = fresh
    lastRefresh = GetGameTimer()
end

--- Drop a plate from the registry (it left state 2). Next refresh re-reads the DB anyway.
function MDP.Streamer.Forget(plate) if plate then registry[plate] = nil end end

--- Add/refresh one plate from the DB (after something put it in state 2).
function MDP.Streamer.Track(plate)
    local r = MySQL.single.await([[SELECT plate, model, vtype, props, fuel, engine, body, mileage, coords, heading
        FROM mdp_vehicles WHERE plate = ? AND state = ?]], { plate, VS.PARKED_WORLD })
    if r then local c = decodeCoords(r.coords); if c then r.pos = c; registry[plate] = r end end
end

local function playerPositions()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(id)
        if ped and ped ~= 0 then out[#out + 1] = GetEntityCoords(ped) end
    end
    return out
end

local function nearest(pos, players)
    local best = math.huge
    for i = 1, #players do
        local d = #(players[i] - pos)
        if d < best then best = d end
    end
    return best
end

local function spawnParked(r)
    Security.WithLock(r.plate, 0, function()
        if Security.GetSpawnedEntity(r.plate) then return end
        local still = MySQL.scalar.await('SELECT 1 FROM mdp_vehicles WHERE plate = ? AND state = ?', { r.plate, VS.PARKED_WORLD })
        if not still then registry[r.plate] = nil return end
        local veh = MDP.Props.SpawnVehicle(r, r.pos.x, r.pos.y, r.pos.z, tonumber(r.heading) or 0.0, nil)
        if veh then
            FreezeEntityPosition(veh, false)
            SetVehicleDoorsLocked(veh, 2) -- parked cars stay locked; keys adapter unlocks for holders
        else
            print(('^3[mdp_garages] streamer: spawn failed for %s^0'):format(r.plate))
        end
    end)
end

local function despawnParked(r, veh)
    Security.WithLock(r.plate, 0, function()
        if Security.GetSpawnedEntity(r.plate) ~= veh or not Utils.IsVehicleEmpty(veh) then return end
        local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
        local engine, body = GetVehicleEngineHealth(veh), GetVehicleBodyHealth(veh)
        local moved = #(c - r.pos) > 0.5
        local damaged = math.abs(engine - (tonumber(r.engine) or 1000)) > 1 or math.abs(body - (tonumber(r.body) or 1000)) > 1
        if moved or damaged then
            local n = MySQL.update.await('UPDATE mdp_vehicles SET coords = ?, heading = ?, engine = ?, body = ? WHERE plate = ? AND state = ?',
                { json.encode({ x = c.x, y = c.y, z = c.z }), h, engine, body, r.plate, VS.PARKED_WORLD })
            if n == 1 then r.pos, r.heading, r.engine, r.body = c, h, engine, body end
        end
        Security.UntrackSpawn(r.plate)
        DeleteEntity(veh)
    end)
end

--- A driver took a parked car (owner/key holder; the keys resource controls who can drive): it is OUT now.
local function becameDriven(r, veh, driverPed)
    Security.WithLock(r.plate, 0, function()
        local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, parked_at = NULL WHERE plate = ? AND state = ?',
            { VS.OUT, r.plate, VS.PARKED_WORLD })
        if n == 1 then
            registry[r.plate] = nil
            for _, id in ipairs(GetPlayers()) do
                if GetPlayerPed(id) == driverPed then Security.ClaimSpawn(r.plate, tonumber(id)) break end
            end
        end
    end)
end

local function tick()
    if not MDP.Ready then return end
    if GetGameTimer() - lastRefresh > (Config.StreamerRefreshMs or 30000) then MDP.Streamer.Refresh() end
    local players = playerPositions()
    local spawnR = Config.WorldSpawnRadius or 150.0
    local despawnR = spawnR + (Config.DespawnMargin or 50.0)
    for plate, r in pairs(registry) do
        local veh = Security.GetSpawnedEntity(plate)
        if veh then
            local driver = GetPedInVehicleSeat(veh, -1)
            if driver and driver ~= 0 then
                becameDriven(r, veh, driver)
            elseif nearest(GetEntityCoords(veh), players) > despawnR then
                despawnParked(r, veh)
            end
        elseif not pending[plate] and #players > 0 and nearest(r.pos, players) <= spawnR then
            pending[plate] = true
            CreateThread(function()
                local ok, err = pcall(spawnParked, r)
                if not ok then print(('^1[mdp_garages] streamer spawn error %s: %s^0'):format(plate, tostring(err))) end
                pending[plate] = nil
            end)
        end
    end
end

CreateThread(function()
    while true do
        Wait(Config.StreamerTickMs or 1500)
        local ok, err = pcall(tick)
        if not ok then print('^1[mdp_garages] streamer tick failed: ' .. tostring(err) .. '^0') end
    end
end)
