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
2. **Run `sql/install.sql`** on your database (HeidiSQL or the `mysql` CLI). It isn't applied automatically, and it's safe to re-run.
3. `server.cfg`. Start order matters:
   ```cfg
   ensure oxmysql
   ensure ox_lib
   ensure qbx_core        # or qb-core / es_extended
   # ensure fuel/keys/billing resources here
   ensure mdp_garages
   ```
4. Optional: migrate existing vehicles (below).

## Database
Tables are prefixed `mdp_` so they don't clash with ESX `owned_vehicles` or QB `player_vehicles`: `mdp_vehicles`, `mdp_vehicle_keys`, `mdp_private_garages`, `mdp_impound`, `mdp_fines`, `mdp_fine_invoices`, `mdp_schema_version`. **`mdp_vehicles` is the source of truth.** Framework tables are only read.

## Migration and sync
- **Automatic sync** (`Config.SyncFrameworkTables = true`): when a player loads, any of their plates in the framework table that are missing from `mdp_vehicles` get imported. This means dealership purchases show up without code changes.
- **One-off migration:** set `Config.Migration.Enabled = true` (it runs once at start) or run `mdp_migrate` in the console. It imports only the detected framework's table, in batches, with `INSERT IGNORE`. ESX `type`, `job` and `stored` are respected (see `Config.Migration`).
- **Dealerships** can call the export directly (below).

## Exports (server)
```lua
-- returns ok:boolean, err?:string
local ok, err = exports.mdp_garages:AddVehicle(owner, plate, model, props, garageId)
-- owner: ESX identifier / QB citizenid · plate: 1-8 chars [A-Z0-9 ] · model: spawn name
-- props: table or JSON (optional) · garageId: 'public:<id>' (optional, defaults to Config.DefaultGarage)
-- errors: invalid_owner, invalid_plate, invalid_model, invalid_props, plate_exists, db_error
```
## Exports (client)
`OpenGarageUI(view, data)`, `UpdateGarageUI(data, view?)`, `CloseGarageUI()`.

## Commands
| Command | Who | Description |
|---|---|---|
| `mdp_migrate` | console, or ace `command.mdp_migrate` | import from the framework vehicle table |
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
| `MaxGarageDistance` / `MaxVehicleDistance` | `10.0` / `5.0` | server-side distance checks |
| `PlateMaxLength` | `8` | plate rule 1-8 `[A-Z0-9 ]` |
| `Security` | `{ownedTable='mdp_vehicles'}` | passed to server/security.lua |
| `SyncFrameworkTables` | `true` | import missing plates on player load |
| `Migration` | see file | `Enabled`, `Ace`, `VehicleTypes`, `SkipJobVehicles`, `NotStored`, `BatchSize` |
| `OnRestartOutVehicles` | `'park'` | `park` (to last coords) or `garage` (to DefaultGarage) |
| `MaxWorldParkedPerPlayer` / `MaxWorldParkedServer` | `5` / `150` | parking is refused at the limit |
| `AutoImpoundOldest` | `false` | impound the oldest car at the global limit instead |
| `WorldSpawnRadius` / `DespawnMargin` | `150.0` / `50.0` | proximity spawn with hysteresis |
| `SaveInterval` | `300000` | ms; only changed vehicles are saved |
| `InactivityRetireHours` | `72` | phase 7, not used yet |
| `BlockOnUnpaidFines` / `UnpaidFinesThreshold` | `false` / `3` | block taking cars out |
| `ImpoundReasons` | 3 examples | reasonId → fee/hours (server-side only) |
| `MileageUnit` | `'km'` | `km` / `mi` |
| `KeyHoldersSeeLocation` | `true` | owners always see location |
| `DefaultGarage` / `Garages` | `public:legion` / legion, pillbox, sandy, impound:lspd | garage definitions |

## Framework notes
- **Qbox:** detected before qb-core, because Qbox also provides the qb-core compatibility layer. Uses `exports.qbx_core` (citizenid, `GetMoney`/`RemoveMoney`, `Notify`).
- **QBCore:** citizenid, `Player.Functions.RemoveMoney`, job `grade.level`, `onduty`.
- **ESX:** `identifier`, the `cash` account maps to ESX `money`, and `job.onDuty` is used only when it's a boolean (`Config.ESXAssumeOnDuty` otherwise).
- **Standalone:** prints a red warning. Identifiers come from the FiveM license, and all money removal fails.
- Plates are 1-8 characters `[A-Z0-9 ]` after trimming, collapsing spaces and uppercasing. The DB column is `VARCHAR(12)`.

## Restart behaviour
On start, vehicles left OUT are converted atomically (parked at their last coords, or sent to the default garage), and leftover entities are cleaned up. Nothing depends on memory from a previous run.
