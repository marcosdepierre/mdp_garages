-- Phase 1: parked-vehicle streamer (state 2 PARKED_WORLD). Security requirements (docs/security-review-phase1.md):
--  1 every spawn/despawn/adoption inside Security.WithLock(plate, 0, fn); no spawn if Security.GetSpawnedEntity(plate)
--  2 the row is re-read inside the lock and must still be state = PARKED_WORLD (also before despawn, N9)
--  3 model / coords / heading / props from the DB only
--  4 spawn in pcall (MDP.Props.SpawnVehicle deletes partial entities); failures retry with exponential backoff
--  5 TrackSpawn + mdp_plate after DoesEntityExist
--  6 adoption (N1): only via Security.CanAdopt (server-marked entity, model, empty, within ParkedMoveTolerance of DB coords);
--    rejected+empty -> deleted, rejected+occupied -> ignored; duplicates: none adopted, logged
--  7 at most Config.StreamerMaxSpawnsPerTick spawns per tick
-- Despawn: props snapshot from the network owner (token only to the owner, single use, TTL), then save + delete.
-- Driver in a parked car: becomes OUT only if the driver is owner/key holder (N4).
MDP.Streamer = {}
local VS = Constants.VehicleState
local SELECT_ROW = [[SELECT plate, owner, model, vtype, props, fuel, engine, body, mileage, coords, heading, state,
    UNIX_TIMESTAMP(COALESCE(parked_at, updated_at)) AS mileage_ts FROM mdp_vehicles WHERE plate = ? AND state = ?]]
local registry = {}   -- plate -> { plate, pos } (positions only; everything else re-read in the lock)
local pending = {}    -- plate -> true while a spawn thread runs
local backoff = {}    -- plate -> { fails, nextTry }
local snaps = {}      -- plate -> { token, veh, owner, expires, props?, partial?, done }
local driveDenied = {} -- plate -> last log time (N4 log throttle)
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
    return c and { plate = r.plate, pos = c } or nil
end

--- N7: forget every per-plate table entry.
local function prune(plate)
    registry[plate], backoff[plate], driveDenied[plate] = nil, nil, nil
end

function MDP.Streamer.Refresh()
    local rows = MySQL.query.await('SELECT plate, coords FROM mdp_vehicles WHERE state = ? AND coords IS NOT NULL',
        { VS.PARKED_WORLD }) or {}
    local fresh = {}
    for _, r in ipairs(rows) do fresh[r.plate] = toEntry(r) end
    registry = fresh
    -- N7 sweep: drop backoff/log entries for plates no longer parked
    for plate in pairs(backoff) do if not fresh[plate] then backoff[plate] = nil end end
    for plate in pairs(driveDenied) do if not fresh[plate] then driveDenied[plate] = nil end end
    lastRefresh = GetGameTimer()
end

function MDP.Streamer.Forget(plate) if plate then prune(plate) end end

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
        if Security.GetSpawnedEntity(plate) then return end
        local row = MySQL.single.await(SELECT_ROW, { plate, VS.PARKED_WORLD })
        if not row then prune(plate) return end
        local pos = decodeCoords(row.coords)
        if not pos then prune(plate) return end
        local ent, matches = Utils.UniqueWorldVehicle(Utils.WorldVehiclesByPlate(), plate, Utils.ModelHash(row.model))
        if matches > 1 then
            print(('^3[mdp_garages] streamer: %d world entities for %s, not spawning (needs review)^0'):format(matches, plate))
            fail(plate) return
        end
        if ent then
            -- N1: Security.CanAdopt -> ok | not_server_entity | model_mismatch | occupied | moved
            local can, why = Security.CanAdopt(ent, plate, pos, Utils.ModelHash(row.model))
            if not can then
                if why ~= 'occupied' and Utils.IsVehicleEmpty(ent) then
                    print(('^3[mdp_garages] streamer: entity for %s not adoptable (%s), deleted^0'):format(plate, tostring(why)))
                    DeleteEntity(ent)
                else
                    print(('^3[mdp_garages] streamer: entity for %s not adoptable (%s) and occupied, ignored^0'):format(plate, tostring(why)))
                end
                fail(plate) return -- retry later (spawns fresh once the world is clear)
            end
            Entity(ent).state:set('mdp_plate', plate, true)
            Security.TrackSpawn(plate, NetworkGetNetworkIdFromEntity(ent), nil)
            MDP.Props.StampMileage(plate) -- N5
            backoff[plate] = nil
            return
        end
        local veh = MDP.Props.SpawnVehicle(row, pos.x, pos.y, pos.z, tonumber(row.heading) or 0.0, nil)
        if not veh then fail(plate) return end
        backoff[plate] = nil
        SetVehicleDoorsLocked(veh, 2) -- parked cars spawn locked (accepted); the keys resource unlocks for holders
    end)
end

--- N2: a replier without ownership/keys may only contribute wear fields (Security.PropSnapshotFields) over the DB props.
local function mergeSnapshot(row, snapProps, partial)
    if not partial then return snapProps end
    local base = MDP.Props.Decode(row.props) or {}
    if base.model == nil then base.model = Utils.ModelHash(row.model) end -- N2b: imported props may lack model
    for k in pairs(Security.PropSnapshotFields or {}) do
        if snapProps[k] ~= nil then base[k] = snapProps[k] end
    end
    return base
end

local function despawnParked(plate, veh, snap)
    Security.WithLock(plate, 0, function()
        if Security.GetSpawnedEntity(plate) ~= veh or not Utils.IsVehicleEmpty(veh) then return end
        -- N9: always re-read the row (registry entry may be missing); only a still-parked row is saved/despawned
        local row = MySQL.single.await(SELECT_ROW, { plate, VS.PARKED_WORLD })
        if not row then return end
        if snap and snap.props then
            local _, propsJson = MDP.Props.Sanitize(mergeSnapshot(row, snap.props, snap.partial), row, veh)
            if propsJson then
                MySQL.update.await('UPDATE mdp_vehicles SET props = ? WHERE plate = ? AND state = ?', { propsJson, plate, VS.PARKED_WORLD })
            else
                print(('^3[mdp_garages] streamer: snapshot props rejected for %s, keeping last saved^0'):format(plate))
            end
        end
        local c, h = GetEntityCoords(veh), GetEntityHeading(veh)
        local engine = MDP.Props.Health('engine', GetVehicleEngineHealth(veh))
        local body = MDP.Props.Health('body', GetVehicleBodyHealth(veh))
        local dbPos = decodeCoords(row.coords)
        local moved = MDP.Props.ValidCoords(c) and (not dbPos or #(c - dbPos) > 0.5)
        local damaged = math.abs(engine - (tonumber(row.engine) or 1000)) > 1 or math.abs(body - (tonumber(row.body) or 1000)) > 1
        if moved or damaged then
            MySQL.update.await([[UPDATE mdp_vehicles SET coords = COALESCE(?, coords), heading = ?, engine = ?, body = ?
                WHERE plate = ? AND state = ?]], { moved and json.encode({ x = c.x, y = c.y, z = c.z }) or nil,
                moved and h or row.heading, engine, body, plate, VS.PARKED_WORLD })
            if moved and registry[plate] then registry[plate].pos = c end
        end
        Security.UntrackSpawn(plate)
        DeleteEntity(veh)
        MDP.Props.ForgetMileage(plate) -- N7
        backoff[plate] = nil
    end)
end

--- Ask the network owner (only it) for a props snapshot; despawn after the reply or the timeout. Async per car.
local function snapshotThenDespawn(plate, veh)
    if snaps[plate] then return end
    local owner = NetworkGetEntityOwner(veh)
    if not owner or owner <= 0 then return despawnParked(plate, veh, nil) end
    local snap = { token = MDP.Props.NewToken(), veh = veh, owner = owner,
        expires = GetGameTimer() + (Config.SnapshotTokenTtlMs or 5000) }
    snaps[plate] = snap
    CreateThread(function()
        TriggerClientEvent('mdp_garages:client:propsSnapshotReq', owner, NetworkGetNetworkIdFromEntity(veh), snap.token)
        local deadline = GetGameTimer() + (Config.SnapshotTimeoutMs or 2000)
        while not snap.done and GetGameTimer() < deadline do Wait(100) end
        if not snap.done then print(('^3[mdp_garages] streamer: no props snapshot for %s (timeout), keeping last saved^0'):format(plate)) end
        snap.token = nil -- consumed / expired
        local ok, err = pcall(despawnParked, plate, veh, snap)
        if not ok then print(('^1[mdp_garages] streamer despawn error %s: %s^0'):format(plate, tostring(err))) end
        snaps[plate] = nil
    end)
end

RegisterNetEvent('mdp_garages:server:propsSnapshot', function(payload)
    local src = source
    if Security.RateLimit and not Security.RateLimit(src, 'ev:propsSnapshot', 10, 5000) then return end
    if type(payload) ~= 'table' or type(payload.props) ~= 'table' or type(payload.token) ~= 'string' then return end
    local netId = math.tointeger(payload.netId)
    if not netId then return end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return end
    local plate = Entity(ent).state.mdp_plate
    local snap = plate and snaps[plate]
    if not snap or snap.done or not snap.token or snap.veh ~= ent or snap.token ~= payload.token or GetGameTimer() > snap.expires then return end
    if NetworkGetEntityOwner(ent) ~= src then
        if Security.LogReject then Security.LogReject(src, 'mdp_garages:server:propsSnapshot', 'not_entity_owner', { plate = plate }) end
        return
    end
    snap.token = nil -- single use
    snap.partial = not Security.IsOwner(src, plate, true) -- N2: strangers only contribute PropSnapshotFields
    snap.props, snap.done = payload.props, true
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, snap in pairs(snaps) do -- N7: a dropped owner can't answer; stop waiting
        if snap.owner == src and not snap.done then snap.token = nil; snap.done = true end
    end
end)

local function becameDriven(plate, veh, driverPed)
    local driverSrc
    for _, id in ipairs(GetPlayers()) do
        if GetPlayerPed(id) == driverPed then driverSrc = tonumber(id) break end
    end
    -- N4: only the owner or a key holder takes the car out of PARKED_WORLD
    if not driverSrc or not Security.IsOwner(driverSrc, plate, true) then
        local now = GetGameTimer()
        if not driveDenied[plate] or now - driveDenied[plate] > 60000 then
            driveDenied[plate] = now
            print(('^3[mdp_garages] streamer: %s driven by %s without ownership/keys, state left PARKED_WORLD^0'):format(plate, tostring(driverSrc or 'npc')))
        end
        return
    end
    Security.WithLock(plate, 0, function()
        if Security.GetSpawnedEntity(plate) ~= veh then return end
        local n = MySQL.update.await('UPDATE mdp_vehicles SET state = ?, parked_at = NULL WHERE plate = ? AND state = ?',
            { VS.OUT, plate, VS.PARKED_WORLD })
        if n ~= 1 then return end
        prune(plate)
        Security.ClaimSpawn(plate, driverSrc)
        MDP.Props.StampMileage(plate) -- N5
        MDP.Props.Hook(Bridge.FrameworkSync, 'OnSpawn', plate)
    end)
end

local function tick()
    if not MDP.Ready then return end
    if GetGameTimer() - lastRefresh > (Config.StreamerRefreshMs or 30000) then MDP.Streamer.Refresh() end
    local players = playerPositions()
    local spawnR = Config.WorldSpawnRadius or 150.0
    local despawnR = spawnR + (Config.DespawnMargin or 50.0)
    local budget = Config.StreamerMaxSpawnsPerTick or 5
    local now = GetGameTimer()
    for plate, r in pairs(registry) do
        local veh = Security.GetSpawnedEntity(plate)
        if veh then
            local driver = GetPedInVehicleSeat(veh, -1)
            if driver and driver ~= 0 then
                becameDriven(plate, veh, driver)
            elseif not snaps[plate] and nearest(GetEntityCoords(veh), players) > despawnR and Utils.IsVehicleEmpty(veh) then
                snapshotThenDespawn(plate, veh)
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
