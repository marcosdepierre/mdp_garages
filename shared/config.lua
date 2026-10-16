-- mdp_garages configuration. Format of each comment: description · values · default.
Config = {}

---------------------------------------------------------------------------
-- General
---------------------------------------------------------------------------
-- Language for _L(). Missing keys fall back to 'en' with a one-time console warning · 'en' | 'es' · 'en'
Config.Locale = 'en'
-- Extra console logging (adapter errors, client load) · boolean · false
Config.Debug = false
-- Framework override. Invalid values or a non-started resource -> red warning + autodetect
-- · 'auto' | 'qbx' | 'qb' | 'esx' | 'standalone' · 'auto'
Config.Framework = 'auto'
-- ESX only: if job.onDuty is not a boolean (older ESX has no duty system), treat players as on duty.
-- Bridge.GetJob returns dutyAssumed = true when this applies · boolean · true
Config.ESXAssumeOnDuty = true
-- Upper cap for any single money operation (Bridge.ValidAmount) · integer > 0 · 1000000
Config.MaxMoneyAmount = 1000000

---------------------------------------------------------------------------
-- Integrations (see docs/integrations.md). 'auto' or an explicit resource name.
---------------------------------------------------------------------------
-- Fuel adapter · 'auto' | 'ox_fuel' | 'cdn-fuel' | 'LegacyFuel' · 'auto'
Config.Fuel    = 'auto'
-- Vehicle keys adapter (plate-based) · 'auto' | 'qbx_vehiclekeys' | 'qb-vehiclekeys' · 'auto'
Config.Keys    = 'auto'
-- Billing adapter, auto order esx_billing > qb-phone > okokBilling (okok never used for fines) · 'auto' | resource name · 'auto'
Config.Billing = 'auto'
-- How fees are charged (Integrations) · 'instant' (Bridge.RemoveMoney now) | 'invoice' (billing adapter) · 'instant'
Config.ChargeMode = 'instant'
-- okokBilling only (fees with ChargeMode = 'invoice', never fines): trust TriggerEvent('okokBilling:CreateCustomInvoice')
-- from the server. TO VERIFY IN-GAME: unknown whether okok accepts it without a client source · boolean · false
Config.OkokTrustServerEvent = false
-- Notify: 'auto' = ox_lib then framework native; 'framework' = the started core's notify · 'auto' | 'ox_lib' | 'framework' | resource · 'auto'
Config.Notify  = 'auto'
-- Phone app adapter · 'auto' | 'lb-phone' | 'npwd' | 'qb-phone' · 'auto'
Config.Phone   = 'auto'

---------------------------------------------------------------------------
-- Security / validation
---------------------------------------------------------------------------
-- Max distance (m) player <-> garage interaction point, checked server-side · number · 10.0
Config.MaxGarageDistance = 10.0
-- Max distance (m) player <-> vehicle for vehicle actions, checked server-side · number · 5.0
Config.MaxVehicleDistance = 5.0
-- Max plate length after normalization (GTA plates are 8; DB column is VARCHAR(12)) · 1-8 · 8
Config.PlateMaxLength = 8
-- Passed to server/security.lua (Security Engineer) · table
--   ownedTable: vehicles table · 'mdp_vehicles'
--   despawnOnDropMs: after a player drops, vehicles still tracked and unclaimed after this many ms are saved and sent
--                    to DefaultGarage (Security.OnDroppedVehicleTimeout). nil = disabled · integer|nil · nil
--                    Note: with OnDisconnect = 'keep' this would garage the cars left parked; enable deliberately.
Config.Security = { ownedTable = 'mdp_vehicles', despawnOnDropMs = nil }

---------------------------------------------------------------------------
-- Source of truth / framework tables
---------------------------------------------------------------------------
-- On player load, import plates missing from mdp_vehicles out of owned_vehicles / player_vehicles
-- (INSERT IGNORE, originals untouched) so dealership purchases appear · boolean · true
Config.SyncFrameworkTables = true
-- Mirror mdp_vehicles -> framework tables on store/spawn/impound (Integrations bridge/vehicle/framework_sync.lua; UPDATE only) · boolean · defaults to SyncFrameworkTables
Config.MirrorFrameworkTables = Config.SyncFrameworkTables
-- Remove TEMPORARY keys when a vehicle is stored in a garage (state 1); kept for world parking (Bridge.Keys.OnStore) · boolean · true
Config.RemoveKeysOnStore = true
-- During a player's sync, SOFT-DELETE (state 5 REMOVED) their vehicles that no longer exist in the framework table
-- (fines/impound/keys kept; despawned only if empty, else deferred; restored if the plate reappears). Only rows with source='framework' (imported by sync/migrate), only after a successful query;
-- skipped with a warning if the framework returns 0 rows while framework-sourced vehicles exist · boolean · true
Config.SyncRemovals = true
-- One-off importer (sql/migrate.lua). Enabled = run once on start; also restricted command `mdp_migrate`
--   Ace: ace permission for in-game use · string · 'command.mdp_migrate'
--   VehicleTypes: ESX `type` -> import? (unknown types skipped) · table · cars only
--   SkipJobVehicles: skip rows with a non-empty ESX `job` column · boolean · true
--   NotStored: ESX stored=0 maps to · 'out' (storable at a garage) | 'garaged' | 'impounded' · 'out'
Config.Migration = {
    Enabled = false,
    Ace = 'command.mdp_migrate',
    VehicleTypes = { car = true, automobile = true },
    SkipJobVehicles = true,
    NotStored = 'out',
    BatchSize = 500, -- rows per multi-row INSERT · integer · 500
}
-- ESX `parking` column value -> mdp garage id, applied by migrate/sync BEFORE Utils.ResolveGarageId.
-- Unmapped values become 'public:<value>' and fall back to DefaultGarage if unknown · table · examples below
Config.ESXParkingMap = {
    ['SanAndreasAvenue'] = 'public:legion',
    ['LegionSquare']     = 'public:legion',
    ['PillboxHill']      = 'public:pillbox',
    ['SandyShores']      = 'public:sandy',
}

---------------------------------------------------------------------------
-- Restart / persistence
---------------------------------------------------------------------------
-- Vehicles still OUT (state 0) at resource start whose entity still exists (adopted by plate+model):
-- · 'park' (-> 2 where the entity is, if empty) | 'garage' (-> 1 in DefaultGarage, entity deleted) · 'park'
-- OUT vehicles WITHOUT a live entity always go to DefaultGarage.
Config.OnRestartOutVehicles = 'park'
-- What happens to a tracked vehicle the player was DRIVING when they disconnect
-- · 'keep' (state 2 at its position, parked_at=NOW, coords/heading/health saved) | 'garage' (state 1 in DefaultGarage,
--   entity deleted) | 'impound' (state 3, DisconnectImpoundReason, entity deleted) · 'keep'
Config.OnDisconnect = 'keep'
-- Impound reason id (Config.ImpoundReasons) and lot used by OnDisconnect = 'impound' · string · 'abandoned' / 'impound:lspd'
Config.DisconnectImpoundReason = 'abandoned'
Config.DefaultImpound = 'impound:lspd'
-- Phase 1 streamer: tick interval (ms) over player coords, and full registry refresh from DB (ms). Defaults 1500 / 30000.
Config.StreamerTickMs = 1500
Config.StreamerRefreshMs = 30000
-- Max parked-vehicle spawns started per streamer tick (avoids entity spikes) · integer · 5
Config.StreamerMaxSpawnsPerTick = 5
-- Hard cap of km accepted per store/park over the DB odometer (mileage never decreases) · number · 50
Config.MaxMileageDeltaKm = 50
-- Time-based km cap: max plausible speed (km/h) since the last mileage update, plus a fixed margin (km) · 400 / 0.5
Config.MaxSpeedKmh = 400
Config.MileageMarginKm = 0.5
-- Streamer: wait this long (ms) for the network owner's props snapshot before despawning a parked car · 2000
Config.SnapshotTimeoutMs = 2000
-- Snapshot token lifetime (ms); single use, sent only to the entity owner · 5000
Config.SnapshotTokenTtlMs = 5000

-- takeOut of a world-parked car (state 2) is refused if it moved more than this (m) from its stored coords · number · 5.0
-- Store/park with a shared key instead of being the owner · boolean · false (reserved for phase 3; keys are for driving only)
Config.AllowSharedKeyStore = false
Config.ParkedMoveTolerance = 5.0
-- Max world-parked vehicles per player; at the limit parking is refused · integer · 5
Config.MaxWorldParkedPerPlayer = 5
-- Max world-parked vehicles on the server; at the limit parking is refused (see AutoImpoundOldest) · integer · 150
Config.MaxWorldParkedServer = 150
-- Global limit only: impound the oldest world-parked car instead of refusing · boolean · false
Config.AutoImpoundOldest = false
-- Server spawns a world-parked car when a player is within this radius (m) · number · 150.0
Config.WorldSpawnRadius = 150.0
-- Despawn only beyond WorldSpawnRadius + DespawnMargin (hysteresis) · number · 50.0
Config.DespawnMargin = 50.0
-- Periodic save interval (ms), only dirty vehicles · integer · 300000 (5 min)
Config.SaveInterval = 5 * 60 * 1000
-- Phase 7 (unused yet): hours parked in world before state 4 RETIRED · integer · 72
Config.InactivityRetireHours = 72

---------------------------------------------------------------------------
-- Fines
---------------------------------------------------------------------------
-- Block takeOut when unpaid fines >= UnpaidFinesThreshold · boolean · false
Config.BlockOnUnpaidFines = false
-- Unpaid (paid=0 only; claiming/voided/paid excluded) mdp_fines rows that trigger the block · integer · 3
Config.UnpaidFinesThreshold = 3

---------------------------------------------------------------------------
-- Impound: fee/time ALWAYS chosen server-side by reason id (client sends reasonId only)
---------------------------------------------------------------------------
-- reasonId -> { label, fee (integer $), hours (release delay) } · table
Config.ImpoundReasons = {
    illegal_parking = { label = 'Illegal parking', fee = 250,  hours = 0 },
    abandoned       = { label = 'Abandoned vehicle', fee = 500, hours = 0 },
    police_hold     = { label = 'Police hold', fee = 1500, hours = 2 },
}

---------------------------------------------------------------------------
-- Wear / UI
---------------------------------------------------------------------------
-- Per-model vehicle type override (wins over GetVehicleType / client class) · { [model] = type } · {}
-- types: 'automobile' | 'bike' | 'boat' | 'heli' | 'plane'
Config.VehicleTypes = {
    -- seashark = 'boat',
}
-- Mileage display unit (DB always stores km) · 'km' | 'mi' · 'km'
Config.MileageUnit = 'km'
-- Key holders also receive vehicle coords (owner always does) · boolean · true
Config.KeyHoldersSeeLocation = true

---------------------------------------------------------------------------
-- Garages. id format kind:<id> (Utils.ParseGarageId); public/impound live here, private in mdp_private_garages.
--   label: display name · string
--   coords: interaction point (vec3) · DIST checks use this
--   radius: ox_lib zone radius (m) · number · 3.0
--   spawns: vec4(x, y, z, heading) spawn points, first free one is used
--   types: vehicle types accepted · { 'automobile' | 'bike' | 'boat' | 'heli' | 'plane', ... } · { 'automobile' }
---------------------------------------------------------------------------
-- Fallback garage for migration, sync and unknown garage ids · garage id · 'public:legion'
Config.DefaultGarage = 'public:legion'
Config.Garages = {
    ['public:legion'] = {
        label = 'Legion Square Parking',
        types = { 'automobile', 'bike' },
        coords = vec3(215.8, -810.1, 30.7),
        radius = 3.0,
        spawns = {
            vec4(229.7, -800.1, 30.6, 157.8),
            vec4(233.0, -801.6, 30.5, 157.8),
            vec4(222.6, -805.0, 30.6, 248.0),
        },
    },
    ['public:pillbox'] = {
        label = 'Pillbox Hill Parking',
        types = { 'automobile', 'bike' },
        coords = vec3(273.8, -344.2, 44.9),
        radius = 3.0,
        spawns = {
            vec4(277.6, -340.6, 44.9, 70.0),
            vec4(278.9, -337.3, 44.9, 70.0),
            vec4(282.6, -330.2, 44.9, 70.0),
        },
    },
    ['public:sandy'] = {
        label = 'Sandy Shores Parking',
        types = { 'automobile', 'bike' },
        coords = vec3(1737.6, 3710.2, 34.1),
        radius = 3.0,
        spawns = {
            vec4(1737.8, 3718.9, 34.0, 21.0),
            vec4(1733.0, 3716.5, 34.1, 21.0),
        },
    },
    ['impound:lspd'] = {
        label = 'LSPD Impound Lot',
        types = { 'automobile', 'bike', 'boat', 'heli', 'plane' },
        coords = vec3(409.3, -1623.0, 29.3),
        radius = 3.0,
        spawns = { vec4(401.9, -1631.6, 29.3, 230.0), vec4(404.4, -1634.0, 29.3, 230.0) },
    },
}
