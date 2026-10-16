# mdp_garages

A standalone garage resource for **Qbox (qbx_core)**, **QBCore (qb-core)** and **ESX (es_extended)**. Planned features: physical persistence, shared keys, free parking with fines and tow, private garages with interiors, police impound with GPS, realistic wear, and a phone app.

> Phase 0: foundation (bridge, schema, security pipeline, restart recovery, NUI plumbing, getVehicles/takeOut). Design details are in [docs/architecture.md](docs/architecture.md), [docs/integrations.md](docs/integrations.md) and [docs/security.md](docs/security.md).

## Dependencies
| Resource | Required | Notes |
|---|---|---|
| [oxmysql](https://github.com/overextended/oxmysql) | yes | MySQL 5.7+ / MariaDB 10.3+ |
| [ox_lib](https://github.com/overextended/ox_lib) | yes | callbacks, notify, zones |
| qbx_core / qb-core / es_extended | one of them | autodetected; standalone mode otherwise (no economy) |
| fuel / keys / billing / phone resources | optional | see docs/integrations.md |

## Installation
1. Copy `mdp_garages` to your `resources` folder. The NUI is prebuilt in `web/dist`. To rebuild it, run `cd web && npm ci && npm run build`.
2. **Run `sql/install.sql`** on your database (HeidiSQL or the `mysql` CLI). It isn't applied automatically, and it's safe to re-run. Databases created by older versions are upgraded automatically on start (missing columns/tables are added idempotently); `sql/upgrade_v2.sql` is a manual alternative for `vtype`. The resource answers `not_ready` until startup recovery has finished.
3. `server.cfg`. Start order matters:
   ```cfg
   ensure oxmysql
   ensure ox_lib
   ensure qbx_core        # or qb-core / es_extended
   # ensure fuel/keys/billing resources here
   ensure mdp_garages

   # permissions
   add_ace group.admin mdp_garages.admin allow     # /mdp_finereview <id> paid|void (server/fine_review.lua)
   add_ace group.admin command.mdp_migrate allow   # mdp_migrate in-game (always allowed from the console)
   add_ace group.admin command.mdp_regularize allow # mdp_regularize <plate>: unmarked car -> garage
   ```
4. Optional: migrate existing vehicles (below).

## Database
Tables are prefixed `mdp_` so they don't clash with ESX `owned_vehicles` or QB `player_vehicles`: `mdp_vehicles`, `mdp_vehicle_keys`, `mdp_private_garages`, `mdp_impound`, `mdp_fines`, `mdp_fine_invoices`, `mdp_schema_version`. **`mdp_vehicles` is the source of truth.** Framework tables are only read.

## Migration and sync
- **Automatic sync** (`Config.SyncFrameworkTables = true`): runs on player load, on resource start for connected players, when the garage is opened (60 s cache) and from `AddVehicle`. Missing plates are imported and owner changes propagate (the previous owner's keys are revoked). With `Config.SyncRemovals`, vehicles that were imported from the framework (`source='framework'`) and later deleted there are **soft-deleted** (state 5 REMOVED; fines and history are kept, and the vehicle is restored if it reappears). Vehicles added with `AddVehicle` (`source='mdp'`) and rows that existed before schema v3 are never removed.
- **One-off migration:** set `Config.Migration.Enabled = true` (it runs once at start) or run `mdp_migrate` in the console. It imports only the detected framework's table, in batches, with `INSERT IGNORE`. ESX `type`, `job` and `stored` are respected (see `Config.Migration`).
- **Dealerships** can call the export directly (below).

## Recommended indexes (framework tables)
Sync queries the framework table by owner. ESX doesn't index `owned_vehicles.owner` by default, so this is recommended (mdp_garages never alters framework tables itself):
```sql
ALTER TABLE owned_vehicles ADD INDEX idx_owner (owner);
```

## Exports (server)
```lua
-- returns ok:boolean, info?:string ('exists' | 'transferred' | 'restored') or err
-- 'restored': the plate was soft-deleted (state 5) and is restored for this owner; its old shared keys are cleared
local ok, info = exports.mdp_garages:AddVehicle(owner, plate, model, props, garageId)
-- owner: ESX identifier / QB citizenid · plate: 1-8 chars [A-Z0-9 ] · model: spawn name
-- props: table or JSON (optional) · garageId: 'public:<id>' (optional, defaults to Config.DefaultGarage),
--   or 'out' if the vehicle is already spawned (it can then be stored at any garage)
-- model: name or numeric hash. Existing plate with another owner = ownership transfer (previous keys revoked)
-- errors: invalid_owner, invalid_plate, invalid_model, invalid_props, transfer_deferred (vehicle out/impounded), db_error
```
## Exports (client)
`OpenGarageUI(view, data)`, `UpdateGarageUI(data, view?)`, `CloseGarageUI()`.

## Commands
| Command | Who | Description |
|---|---|---|
| `mdp_migrate` | console, or ace `command.mdp_migrate` (`add_ace group.admin command.mdp_migrate allow`) | import from the framework vehicle table |
| `mdp_regularize <plate>` | console, or ace `command.mdp_regularize` | delete empty unmarked entities with that plate and send the car to its last garage (or `Config.DefaultGarage`) |
| `mdp_recover` | console | re-run startup recovery after fixing a DB problem (the resource answers `not_ready` until it succeeds) |
| `/mdp_finereview <id> paid\|void` | ace `mdp_garages.admin` | resolve `needs_review` fines (Integrations) |
| `/mdp_payfine <id>` | players | pay a fine from the bank. Refused if the fine was sent as an invoice through a billing resource |

## Configuration (`shared/config.lua`)
Every key is commented in the file as description · values · default. Summary:

| Key | Default | Description |
|---|---|---|
| `Locale` | `'en'` | `en` / `es` |
| `Debug` | `false` | extra logging |
| `Framework` | `'auto'` | `auto`/`qbx`/`qb`/`esx`/`standalone`. Invalid values or a stopped resource fall back to auto with a warning |
| `ESXAssumeOnDuty` | `true` | older ESX without a duty system counts as on duty |
| `MaxMoneyAmount` | `1000000` | cap per money operation |
| `Fuel` / `Keys` / `Billing` / `Notify` / `Phone` | `'auto'` | integration adapters |
| `ChargeMode` | `'instant'` | `instant` or `invoice` |
| `OkokTrustServerEvent` | `false` | okokBilling fees only. **To verify in-game** whether okok accepts the server-side event |
| `MaxGarageDistance` / `MaxVehicleDistance` | `10.0` / `5.0` | server-side distance checks |
| `PlateMaxLength` | `8` | plate rule 1-8 `[A-Z0-9 ]` |
| `Security` | `{ownedTable='mdp_vehicles'}` | passed to server/security.lua |
| `SyncFrameworkTables` | `true` | import missing plates and owner changes from the framework table |
| `SyncRemovals` | `true` | soft-delete (state 5) framework-sourced vehicles that were removed from the framework table (with safety checks) |
| `Migration` | see file | `Enabled`, `Ace`, `VehicleTypes`, `SkipJobVehicles`, `NotStored`, `BatchSize` |
| `OnRestartOutVehicles` | `'park'` | `park` (to last coords) or `garage` (to DefaultGarage) |
| `OnDisconnect` | `'keep'` | driver disconnects: `keep` (parked in place), `garage` (DefaultGarage), `impound` |
| `DisconnectImpoundReason` / `DefaultImpound` | `'abandoned'` / `'impound:lspd'` | used by OnDisconnect = impound |
| `ESXParkingMap` | examples | ESX `parking` value → garage id (migration/sync) |
| `VehicleTypes` | `{}` | per-model type override (`automobile/bike/boat/heli/plane`) |
| `ParkedMoveTolerance` | `5.0` | takeOut of a world-parked car is refused if it moved further than this |
| `MaxWorldParkedPerPlayer` / `MaxWorldParkedServer` | `5` / `150` | parking is refused at the limit |
| `AutoImpoundOldest` | `false` | impound the oldest car at the global limit instead |
| `WorldSpawnRadius` / `DespawnMargin` | `150.0` / `50.0` | proximity spawn with hysteresis |
| `SaveInterval` | `300000` | ms; only changed vehicles are saved |
| `InactivityRetireHours` | `72` | phase 7, not used yet |
| `BlockOnUnpaidFines` / `UnpaidFinesThreshold` | `false` / `3` | block taking cars out |
| `ImpoundReasons` | 3 examples | reasonId → fee/hours (server-side only) |
| `MileageUnit` | `'km'` | `km` / `mi` |
| `KeyHoldersSeeLocation` | `true` | owners always see location |
| `DefaultGarage` / `Garages` | `public:legion` / legion, pillbox, sandy, impound:lspd | garage definitions: `label`, `coords`, `radius`, `spawns`, `types` |

## Framework notes
- **Qbox:** detected before qb-core, because Qbox also provides the qb-core compatibility layer. Uses `exports.qbx_core` (citizenid, `GetMoney`/`RemoveMoney`, `Notify`).
- **QBCore:** citizenid, `Player.Functions.RemoveMoney`, job `grade.level`, `onduty`.
- **ESX:** `identifier`, the `cash` account maps to ESX `money`, and `job.onDuty` is used only when it's a boolean (`Config.ESXAssumeOnDuty` otherwise).
- **Standalone:** prints a red warning. Identifiers come from the FiveM license, and all money removal fails.
- Plates are 1-8 characters `[A-Z0-9 ]` after trimming, collapsing spaces and uppercasing. The DB column is `VARCHAR(12)`.

## Vehicle types
Garages accept the vehicle types listed in their `types` (automobile, bike, boat, heli, plane). The type is detected on store (config override, then the server native, then the client class) and is used when the vehicle is spawned.

## Restart behaviour
On start, vehicles left OUT are reconciled with the world. If an entity with the plate and model still exists, it's adopted (parked where it is with `'park'`, or garaged with `'garage'`); otherwise the vehicle goes to `Config.DefaultGarage`. Nothing depends on memory from a previous run. When a player disconnects while driving one of our vehicles, `Config.OnDisconnect` applies.

## Optional server.cfg hardening
```
set mdp_garages_entity_secret "<long random string>"   # secret for the server-entity tag used to adopt vehicles after restarts
set sv_entityLockdown relaxed                           # or strict
set sv_filterRequestControl 2
```
See docs/architecture.md (Phase 1 security re-review) and docs/security.md.

## Release notes / upgrading
- **a8fda43 (phase 1, server entity mark):** vehicles spawned before this version carry no server mark. On the **first restart after updating**, such entities can't be adopted: if empty they are **deleted** (parked cars are respawned by the streamer from the DB, nothing is lost); if **occupied** they are **ignored** and their DB row stays OUT, so the owner can store them normally (no duplicate, P1R3-H1).
- **Strongly recommended:** set `set mdp_garages_entity_secret "<long random string>"` in server.cfg so the server mark is stable and unforgeable across restarts.
- **Owner-only store/park:** only the owner's own, server-spawned vehicle can be stored/parked (keys don't count). Cars spawned before a8fda43 or by other scripts carry no server mark and are refused with "This is not the registered vehicle". Fix them with the admin command `mdp_regularize <plate>` (sends the car to its last garage, deleting the empty unmarked entity). Add `add_ace group.admin command.mdp_regularize allow`.

### Dealerships
0. Both dealership exports (`SpawnOwnedVehicle`, `RegisterExternalVehicle`) only accept calls from resources listed in `Config.TrustedResources` (shared/config.lua), e.g. `Config.TrustedResources = { 'my_dealership' }`. Otherwise they return `untrusted_resource` and print `add "<res>" to Config.TrustedResources in shared/config.lua`.
1. **Primary:** `local netId, err = exports.mdp_garages:SpawnOwnedVehicle(plate, vector4(x, y, z, h), src)` after `AddVehicle(owner, plate, model, props?, 'out')` (server only). The car gets the server mark and can be stored/parked later.
2. Or `AddVehicle(owner, plate, model, props?, 'public:legion')` and the player takes it out from that garage.
3. If your dealership spawns the car itself: the owner's **first store** adopts it (`Config.AllowFirstStoreAdoption = true`, within 30 min of `AddVehicle`, owner driving, script-spawned entity), or call `exports.mdp_garages:RegisterExternalVehicle(netId, plate)` within 60 s of `AddVehicle` after adding your resource to `Config.TrustedResources`.
Framework-only dealerships (writing straight to `owned_vehicles`/`player_vehicles`): a car bought by a player mdp already knows is imported on their next sync as a *new detection* and is adoptable on first store for 30 min; first syncs, `mdp_migrate` and the initial import never are.
Unmarked cars outside these rules are refused (`vehicle_mismatch`); fix them with `mdp_regularize <plate>`.
- **Schema v5:** `managed_at`, `mdp_synced_owners`, `mdp_meta` are added automatically on start (no manual SQL); existing vehicles are backfilled and existing owners seeded, so no old car becomes adoptable after upgrading.
