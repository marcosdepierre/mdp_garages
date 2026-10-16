-- Phase 1: parked-vehicle streamer (state 2 PARKED_WORLD). Meets docs/security-review-phase1.md streamer requirements:
--  1 every spawn/despawn inside Security.WithLock(plate, 0, fn); no spawn if Security.GetSpawnedEntity(plate) exists
--  2 the row is re-read inside the lock and must still be state = PARKED_WORLD
--  3 model / coords / heading / props from the DB only (props were sanitized when saved)
--  4 spawn in pcall (MDP.Props.SpawnVehicle); on failure state untouched, retry with exponential backoff
--  5 TrackSpawn + mdp_plate after DoesEntityExist
--  6 an untracked world entity with the same plate+model is adopted instead of spawning (duplicates: none, logged)
--  7 at most Config.StreamerMaxSpawnsPerTick spawns started per tick
-- Despawn (empty, nearest player > WorldSpawnRadius + DespawnMargin): save coords/heading/health if changed, delete.
-- A driver in a parked car makes it OUT (0) and ClaimSpawn for that driver.
MDP.Streamer = {}
local VS = Constants.VehicleState
local SELECT_ROW = [[SELECT plate, model, vtype, props, fuel, engine, body, mileage, coords, heading
    FROM mdp_vehicles WHERE plate = ? AND state = ?]]
local registry = {}   -- plate -> { plate, pos = vec3, engine, body }  (positions only; spawn data re-read in the lock)
local pending = {}    -- plate -> true while a spawn thread runs
local backoff = {}    -- plate -> { fails, nextTry }
local lastRefresh = 0

local function decodeCoords(raw)
    local ok, c = pcall(json.decode, raw or '')
    if ok and type(c) == 'table' and tonumber(c.x) and tonumber(c.y) and tonumber(c.z) then
        local v = vec3(c.x + 0.0, c.y + 0.0, c.z + 0.0)
        if MDP.Props.ValidCoords(v) then return v end
    end
    return nil
end

local function toEntry(r)
    local c = decodeCoords(r.coords)
    return c and { plate = r.plate, pos = c, heading = tonumber(r.heading) or 0.0, engine = r.engine, body = r.body } or nil
end

function MDP.Streamer.Refresh()
    local rows = MySQL.query.await([[SELECT plate, coords, heading, engine, body FROM mdp_vehicles
        WHERE state = ? AND coords IS NOT NULL]], { VS.PARKED_WORLD }) or {}
    local fresh = {}
    for _, r in ipairs(rows) do fresh[r.plate] = toEntry(r) end
    registry = fresh
    lastRefresh = GetGameTimer()
end

function MDP.Streamer.Forget(plate) if plate then registry[plate] = nil; backoff[plate] = nil end end

function MDP.Streamer.Track(plate)
    local r = MySQL.single.await(SELECT_ROW, { plate, VS.PARKED_WORLD })
    if r then registry[plate] = toEntry(r) end
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
    for i = 1, #players do local d = #(players[i] - pos); if d < best then best = d end end
    return best
end

local function fail(plate)
    local b = backoff[plate] or { fails = 0 }
    b.fails = b.fails + 1
    b.nextTry = GetGameTimer() + math.min(120000, 2000 * (2 ^ (b.fails - 1)))
    backoff[plate] = b
end

local function spawnParked(plate)
    Security.WithLock(plate, 0, function()
        if Security.GetSpawnedEntity(plate) then return end                       -- (1)
        local row = MySQL.single.await(SELECT_ROW, { plate, VS.PARKED_WORLD })     -- (2)(3)
        if not row then registry[plate] = nil return end
        local pos = decodeCoords(row.coords)
        if not pos then registry[plate] = nil return end
        -- (6) adopt an untracked entity with the same plate+model (e.g. left from before a restart)
        local ent, matches = Utils.UniqueWorldVehicle(Utils.WorldVehiclesByPlate(), plate, Utils.ModelHash(row.model))
        if matches > 1 then
            print(('^3[mdp_garages] streamer: %d world entities for %s, not spawning (needs review)^0'):format(matches, plate))
            fail(plate) return
        end
        if ent then
            Entity(ent).state:set('mdp_plate', plate, true)
            Security.TrackSpawn(plate, NetworkGetNetworkIdFromEntity(ent), nil)
            backoff[plate] = nil
            return
        end
        local veh = MDP.Props.SpawnVehicle(row, pos.x, pos.y, pos.z, tonumber(row.heading) or 0.0, nil) -- (4)(5)
        if not veh then fail(plate) return end
        backoff[plate] = nil
        SetVehicleDoorsLocked(veh, 2) -- parked cars stay locked; the keys resource unlocks for holders
    end)
end

local function despawnParked(plate, veh)
    Security.WithLock(plate, 0, function()
        if Security.GetSpawnedEntity(plate) ~= veh or not Utils.IsVehicleEmpty(veh) then return end
        local r = registry[plate]
        local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
        local engine = MDP.Props.Health('engine', GetVehicleEngineHealth(veh))
        local body = MDP.Props.Health('body', GetVehicleBodyHealth(veh))
        local moved = r and MDP.Props.ValidCoords(c) and #(c - r.pos) > 0.5
        local damaged = r and (math.abs(engine - (tonumber(r.engine) or 1000)) > 1 or math.abs(body - (tonumber(r.body) or 1000)) > 1)
        if moved or damaged then
            local coordsJson = moved and json.encode({ x = c.x, y = c.y, z = c.z }) or nil
            local n = MySQL.update.await([[UPDATE mdp_vehicles SET coords = COALESCE(?, coords), heading = ?, engine = ?, body = ?
                WHERE plate = ? AND state = ?]], { coordsJson, moved and h or r.heading, engine, body, plate, VS.PARKED_WORLD })
            if n == 1 then
                if moved then r.pos, r.heading = c, h end
                r.engine, r.body = engine, body
            end
        end
        Security.UntrackSpawn(plate)
        DeleteEntity(veh)
    end)
end

local function becameDriven(plate, veh, driverPed)
    Security.WithLock(plate, 0, function()
        if Security.GetSpawnedEntity(plate) ~= veh then return end
        local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, parked_at = NULL WHERE plate = ? AND state = ?',
            { VS.OUT, plate, VS.PARKED_WORLD })
        if n ~= 1 then return end
        registry[plate] = nil
        for _, id in ipairs(GetPlayers()) do
            if GetPlayerPed(id) == driverPed then Security.ClaimSpawn(plate, tonumber(id)) break end
        end
        MDP.Props.Hook(Bridge.FrameworkSync, 'OnSpawn', plate)
    end)
end

local function tick()
    if not MDP.Ready then return end
    if GetGameTimer() - lastRefresh > (Config.StreamerRefreshMs or 30000) then MDP.Streamer.Refresh() end
    local players = playerPositions()
    local spawnR = Config.WorldSpawnRadius or 150.0
    local despawnR = spawnR + (Config.DespawnMargin or 50.0)
    local budget = Config.StreamerMaxSpawnsPerTick or 5                              -- (7)
    local now = GetGameTimer()
    for plate, r in pairs(registry) do
        local veh = Security.GetSpawnedEntity(plate)
        if veh then
            local driver = GetPedInVehicleSeat(veh, -1)
            if driver and driver ~= 0 then
                becameDriven(plate, veh, driver)
            elseif nearest(GetEntityCoords(veh), players) > despawnR then
                despawnParked(plate, veh)
            end
        elseif budget > 0 and not pending[plate] and #players > 0 and nearest(r.pos, players) <= spawnR
            and (not backoff[plate] or now >= backoff[plate].nextTry) then
            budget = budget - 1
            pending[plate] = true
            CreateThread(function()
                local ok, err = pcall(spawnParked, plate)
                if not ok then print(('^1[mdp_garages] streamer spawn error %s: %s^0'):format(plate, tostring(err))); fail(plate) end
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
