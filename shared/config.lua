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
-- Billing adapter, auto order okokBilling > esx_billing > qb-phone · 'auto' | resource name · 'auto'
Config.Billing = 'auto'
-- How fees are charged (Integrations) · 'instant' (Bridge.RemoveMoney now) | 'invoice' (billing adapter) · 'instant'
Config.ChargeMode = 'instant'
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
-- Passed to server/security.lua (Security Engineer) · table · { ownedTable = 'mdp_vehicles' }
Config.Security = { ownedTable = 'mdp_vehicles' }

---------------------------------------------------------------------------
-- Source of truth / framework tables
---------------------------------------------------------------------------
-- On player load, import plates missing from mdp_vehicles out of owned_vehicles / player_vehicles
-- (INSERT IGNORE, originals untouched) so dealership purchases appear · boolean · true
Config.SyncFrameworkTables = true
-- One-off importer (sql/migrate.lua). Enabled = run once on start; also restricted command `mdp_migrate`
--   Ace: ace permission for in-game use · string · 'command.mdp_migrate'
--   VehicleTypes: ESX `type` -> import? (unknown types skipped) · table · cars only
--   SkipJobVehicles: skip rows with a non-empty ESX `job` column · boolean · true
--   NotStored: ESX stored=0 maps to · 'garaged' | 'impounded' · 'garaged'
Config.Migration = {
    Enabled = false,
    Ace = 'command.mdp_migrate',
    VehicleTypes = { car = true, automobile = true },
    SkipJobVehicles = true,
    NotStored = 'garaged',
    BatchSize = 500, -- rows per multi-row INSERT · integer · 500
}

---------------------------------------------------------------------------
-- Restart / persistence
---------------------------------------------------------------------------
-- What happens to vehicles still OUT (state 0) when the resource starts
-- · 'park' (-> 2 at last known coords; no coords -> garage) | 'garage' (-> 1 in DefaultGarage) · 'park'
Config.OnRestartOutVehicles = 'park'
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
---------------------------------------------------------------------------
-- Fallback garage for migration, sync and unknown garage ids · garage id · 'public:legion'
Config.DefaultGarage = 'public:legion'
Config.Garages = {
    ['public:legion'] = {
        label = 'Legion Square Parking',
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
        coords = vec3(1737.6, 3710.2, 34.1),
        radius = 3.0,
        spawns = {
            vec4(1737.8, 3718.9, 34.0, 21.0),
            vec4(1733.0, 3716.5, 34.1, 21.0),
        },
    },
    ['impound:lspd'] = {
        label = 'LSPD Impound Lot',
        coords = vec3(409.3, -1623.0, 29.3),
        radius = 3.0,
        spawns = { vec4(401.9, -1631.6, 29.3, 230.0), vec4(404.4, -1634.0, 29.3, 230.0) },
    },
}
