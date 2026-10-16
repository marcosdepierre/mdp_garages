# mdp_garages — Architecture (phase 0)

Standalone garage resource for **Qbox (qbx_core)**, **QBCore (qb-core)** and **ESX (es_extended)**.
Whole-project scope: physical persistence, shared keys, free parking with fines and tow, private garages with interiors, police impound with GPS, realistic wear, phone app.

Related docs (not written here, owned by teammates):
- [integrations.md](integrations.md): fuel / keys / billing / notify / phone adapters (Integrations Engineer)
- [security.md](security.md) and `server/security.lua`: validation helpers (Security Engineer)

## Folder layout
```
fxmanifest.lua
shared/      config.lua (every key commented), constants.lua (Constants.VehicleState, SchemaVersion), locale.lua, utils.lua
locales/     en.lua, es.lua
bridge/
  cache.lua           identifier cache (works inside playerDropped)
  init.lua            framework detection, standalone defaults, adapter registry, SafeCall
  framework/          qbx.lua, qb.lua, esx.lua (only the detected one activates)
  notify/init.lua     Bridge.Notify loader (adapter -> ox_lib -> framework native)
  fuel/ keys/ billing/ phone/   init.lua = interface + safe fallback; adapters by Integrations
client/      main.lua (NUI plumbing; exports OpenGarageUI/UpdateGarageUI/CloseGarageUI)
server/      security.lua (Security Engineer), vehicles.lua (import/sync + AddVehicle export), persistence.lua (restart recovery),
             garages.lua (getVehicles/takeOut), fines.lua (payFine + /mdp_payfine), main.lua
web/         React + Untitled UI app (Frontend Engineer); only the built web/dist is served
sql/         install.sql (run manually), migrate.lua (opt-in importer, server script)
docs/        architecture.md, integrations.md, security.md
```
Dependencies: **oxmysql** and **ox_lib** (hard; `@ox_lib/init.lua` is a shared script). Load order: shared, then bridge/init, then framework, then integration folders (`*/*.lua` glob), then client/server. Adapters register with `Bridge.RegisterAdapter(kind, resource, impl)` and are resolved **lazily at call time**, so file order inside a folder doesn't matter.

## Framework detection
`Config.Framework = 'auto'` checks `GetResourceState` (`started`/`starting`) in this order: **qbx_core** (first, because Qbox also provides qb-core compatibility), then **qb-core**, then **es_extended**. If none is found it falls back to **standalone**, prints a red console warning, and stubs money/jobs (RemoveMoney always fails, so nothing is free by accident). Identifier is the FiveM license.

## Bridge API
### Server
| Function | Returns | Notes |
|---|---|---|
| `Bridge.GetPlayer(src)` | framework player object or nil | |
| `Bridge.GetIdentifier(src)` | ESX `identifier` / QB/Qbox `citizenid` | used as `owner`/`holder` in the DB |
| `Bridge.GetJob(src)` | `{name, grade, onduty, onDuty, dutyAssumed?}` | grade is a number (QB `grade.level`). ESX uses `job.onDuty` only if it's a boolean, otherwise `Config.ESXAssumeOnDuty` with `dutyAssumed = true` |
| `Bridge.GetMoney(src, 'cash'\|'bank')` | number | ESX `cash` maps to account `money` |
| `Bridge.RemoveMoney(src, account, amount, reason)` | boolean | refuses non-integer, `<=0`, `> Config.MaxMoneyAmount`, unknown account, insufficient balance |
| `Bridge.Notify(src, msg, type)` | – | bridge/notify: explicit Config.Notify adapter, then ox_lib (mandatory), then framework native |
| `Bridge.ValidAmount(n)` | boolean | shared sanity helper |
| `Bridge.Fuel/Keys/Billing/Phone.Call(fn, fallback, ...)` | result or fallback | pcall-wrapped, never throws |
### Client
`Bridge.Notify(msg, type)`, `Bridge.GetPlayerData()`.

## Database (sql/install.sql)
Tables are prefixed `mdp_` so they don't clash with ESX `owned_vehicles` / QB `player_vehicles`. All use InnoDB and utf8mb4.
| Table | Purpose | Key indexes / FKs |
|---|---|---|
| `mdp_vehicles` | one row per owned vehicle: props, coords JSON, heading, `state` TINYINT, `vtype` (v2), `source` (v3: `framework` = imported by sync/migrate, `mdp` = AddVehicle/own or pre-v3), fuel, engine, body, mileage, garage_id | UNIQUE plate; owner, state, garage_id |
| `mdp_vehicle_keys` | shared keys | UNIQUE(plate, holder); holder; FK plate CASCADE (keys only make sense with the vehicle; vehicles are soft-deleted, so the cascade only fires on a manual hard delete) |
| `mdp_private_garages` | purchased garages with interior; `config_id` = property key from server config | owner; UNIQUE(owner, config_id) stops a double click from buying twice; UNIQUE(owner, label) |
| `mdp_impound` | impound records (fee, release_after, location, released) | plate, released; FK plate CASCADE |
| `mdp_fines` | fines; `owner` NOT NULL (identifier at issue time); `channel` ENUM internal/invoice/external/needs_review; `paid` 0/1/2/3 (unpaid/paid/charging/voided) | plate, owner, paid. **No FK to `mdp_vehicles` (v4)**: fines survive vehicle removal or sale; on upgraded DBs the old FK is dropped at start |
| `mdp_fine_invoices` | billing invoice → fine mapping (`provider`, `invoice_id`, `fine_id`), written by `Bridge.BillingCommon.Link` and read by `Bridge.BillingCommon.OnPaid` (bridge/billing/_common.lua; the table is created by `sql/install.sql`) | PK(provider, invoice_id); fine_id `INT UNSIGNED` FK → `mdp_fines(id)` ON DELETE CASCADE |
| `mdp_schema_version` | applied schema versions (currently **4**: v2 adds `mdp_vehicles.vtype`, v3 adds `mdp_vehicles.source`, v4 drops the FK `mdp_fines → mdp_vehicles` (checked in `information_schema.REFERENTIAL_CONSTRAINTS`) and adds state 5). `server/persistence.lua` checks `information_schema` at start and ALTERs only what's missing; manual alternative for v2: `sql/upgrade_v2.sql`. The server warns at start if the version is lower than `Constants.SchemaVersion` | PK(version) |

`state` constants (`shared/constants.lua`): `Constants.VehicleState`: `0=OUT, 1=GARAGED, 2=PARKED_WORLD, 3=IMPOUNDED, 4=RETIRED, 5=REMOVED`.

`REMOVED` (5) is a **soft delete**: the vehicle was removed from the framework table (`Config.SyncRemovals`). Its row, fines, impound and key rows are kept. It is never sent to the NUI (excluded from `getVehicles`), can't be taken out or stored (`not_found`), doesn't count toward world-parking limits, and is ignored by restart recovery. If the plate reappears in the framework table, sync restores it (GARAGED, or OUT if a live entity exists) with the framework owner. `AddVehicle` on a REMOVED plate also restores it (R5-1): new owner, state OUT with `'out'` or GARAGED in the given/default garage, `source='mdp'`. **Every restore deletes the plate's shared keys** (R5-4), whether or not the owner changed.

`RETIRED` (4) is **phase 7, schema only for now**: a world-parked car left inactive for `Config.InactivityRetireHours` (72 h, measured from `mdp_vehicles.parked_at`, indexed by `(state, parked_at)`) gets removed from the world. It can be recovered from the phone app. No logic exists yet.

## Shared helpers (shared/utils.lua)
- `Utils.NormalizePlate(v)`: trim + upper.
- `Utils.NormalizePlate` also collapses internal whitespace to a single space (`'A  B'` becomes `'A B'`).
- `Utils.IsValidPlate(v)`: after normalizing, **length 1–8 (`Config.PlateMaxLength`), characters `[A-Z0-9 ]` only**. Equivalent to `^[A-Z0-9 ]{1,8}$`. This matches GTA, which truncates plates to 8 characters. The DB column stays `VARCHAR(12)` for headroom.
- `Utils.ParseGarageId(v)` / `Utils.IsValidGarageId(v)`: the single validator for `garage_id`. It must be `public:<id>`, `private:<id>` or `impound:<id>`, where `<id>` is `[A-Za-z0-9_-]` and 1–32 characters. Every garage_id coming from the client or NUI goes through it, and the server then resolves the id against server config or the DB.
- `Utils.ResolveGarageId(garageId, plate) -> id, remapped`: used wherever a stored garage_id is loaded and in migrate.lua. An invalid format, or a `public:` id missing from `Config.Garages`, is remapped to `Config.DefaultGarage` with a console warning that shows the plate and the original value. `private:`/`impound:` ids are checked by format only.
- `Utils.GetGarage(id, expectedKind) -> garage | nil, err`: **every** garage lookup and `distance.getCoords` must go through it. It confirms the garage exists (public/impound in `Config.Garages`; private through the server-set `Utils.PrivateGarageLookup(id)` DB resolver) and that its kind matches the action. Impound garages are only valid for `releaseImpound`; public/private garages are valid for `takeOut`/`storeVehicle`/`getVehicles`. Errors: `invalid_garage`, `wrong_garage_kind`, `unknown_garage`.
- `Utils.ModelHash(model)`: `tonumber(model) or joaat(model)`, normalized to signed 32-bit. **This is the single helper used wherever a model is spawned or compared** (ESX stores numeric hashes, QB stores names).
- `Utils.UILocale()`: the NUI locale table (in `shared/utils.lua`; not a global).
- `Utils.ErrorCode(err)` / `Utils.ErrorText(code)`: normalize to a documented code, and get its localized text.
- `Utils.FormatMileage(km)`: the DB always stores km; display follows `Config.MileageUnit` (`'km'` | `'mi'`).

## Security module (server/security.lua, Security Engineer; see [security.md](security.md))
All state-changing endpoints are registered with **`Security.RegisterSecureCallback(name, opts, handler)`**, which wraps `lib.callback.register`. Its `opts` are:
- `rateLimit = {max, windowMs}`: spawn/store use `{max=1, windowMs=1000}`, queries use `{max=5, windowMs=10000}`.
- `schema = {field = 'plate'|'id'|'int'|'string'|'boolean'|'number'|fn}`. Unknown fields are rejected and `plate` is normalized.
- `job = {names = {...}, minGrade = n, requireDuty? = boolean}`, checked through `Security.HasJob` (which uses `Bridge.GetJob`). Being on duty is **required by default**; pass `requireDuty = false` to skip it. On ESX without a duty system, `Config.ESXAssumeOnDuty` (default true) applies and `GetJob` returns `dutyAssumed = true`.
- `requireOwnership = true`, checked through `Security.IsOwner(src, plate)`, a parameterized query on `mdp_vehicles` (the default table).
  - `Security.IsOwner(src, plate)`: true if the player is the **owner or a key holder** (`mdp_vehicle_keys`).
  - `Security.IsOwner(src, plate, false)`: **owner only** (used for giving/removing keys, private-garage purchase, and so on).
- `distance = {getCoords = fn(src,data), max = n}`. Coords are always resolved from server config or the server entity, never from the payload, and checked with `Security.IsNear`.

- `resolvePlate = Vehicles.ResolvePlateFromNetId`: wraps `Security.PlateFromNetId(netId) -> plate, nil, ent | nil, err`. The server-side plate is stored in `data._plate`; any `_plate` the client sends is stripped. A failure rejects with `plate_unresolved:<err>` (`bad_netid`, `no_entity`, `not_vehicle`, `bad_plate`). `requireOwnership` then checks `data._plate`. **Every netId-based handler** (storeVehicle, parkWorld, towVehicle, issueFine, impoundVehicle, syncWear) uses it, and handlers only ever use `data._plate`.

**Validation order** in `runChecks` (Security): (1) source is valid, (2) rate limit, (3) schema (strips any client `_plate`), (4) `resolvePlate` → `data._plate`, (5) job, (6) distance, (7) DB ownership (`requireOwnership`). The cheap checks run before the DB query.

Other helpers: `Security.WithLock(plate, src, fn, ...)` (per-plate lock, released even if `fn` errors) / `Security.Lock(plate, src) -> token|nil` / `Security.Unlock(plate, token)` (the token ensures only the lock's owner can release it; none of our files call `Lock`/`Unlock` directly, they all use `WithLock`), `Security.IsKeyHolder`, `Security.TrackSpawn` / `UntrackSpawn` / `GetSpawnedEntity` (spawn registry by plate), `Security.RateLimit`, `Security.V.*` validators, `Security.LogReject`, and the `Security.OnSuspicious` hook.

## Server namespace
Server modules hang off one global, `MDP` (`server/core.lua`): `MDP.Ready`, `MDP.Callback` (a `Security.RegisterSecureCallback` wrapper that returns `{ok=false, error='not_ready'}` until startup recovery finishes) and `MDP.Vehicles`. Integration helpers live under `Bridge.*Common`.

## Source of truth and framework tables
`mdp_vehicles` is the source of truth. Framework tables are only read, never written.
- **Diff-based sync** (R3-2): the framework rows are compared against existing `mdp_vehicles` rows. Only **new plates** are inserted (`INSERT IGNORE`, `source='framework'`), and unchanged rows cause no writes.
- **Owner changes** (R3-3) apply only when the mdp row is in state **1 (garaged) or 2 (world-parked)**: `UPDATE … WHERE plate=? AND owner=<old> AND state IN (1,2)`, after which **all keys of the plate are revoked** and the change is logged. If the row is in state 0 (out) or 3 (impounded), the change is logged as deferred and retried at the next sync. `AddVehicle` follows the same rule and returns `false, 'transfer_deferred'`.
- **Initial state on import:** QB `state=0` and ESX `stored=0` (with `Config.Migration.NotStored='out'`, the default) import as **OUT**, but **only if a live entity with that plate exists**; otherwise they import as GARAGED in their garage or `DefaultGarage` (R4-1). As OUT, so a freshly bought car can be stored at a garage. `AddVehicle(..., 'out')` does the same for a vehicle that's already spawned.
- Recommended for ESX (not created by us): `ALTER TABLE owned_vehicles ADD INDEX (owner);`, because sync queries by owner.
- **Removals** (`Config.SyncRemovals = true`): during a player's sync, their rows with **`source='framework'`** whose plate no longer exists in the framework table are **soft-deleted** (`state = 5 REMOVED`). No row is deleted, so **unpaid fines can't be escaped by selling the car**. A world entity for the plate is untracked and despawned, but **only if it's empty**; if anyone is inside, the removal is deferred to the next sync (R3b-2). Each removal is logged, and the row is restored if the plate reappears. If the plate still exists under another owner, it is transferred instead. Safety rules:
  - only `source='framework'` rows are touched (never `AddVehicle` rows or rows that existed before v3);
  - removals only run when the framework table exists and the query succeeded;
  - if the framework returns **zero rows** while the player has framework-sourced vehicles, removals are skipped with a warning, since that could be a transient issue.
- **Sync triggers:** player load (forced); resource start for players already connected (after recovery); inside `AddVehicle` when the owner is online; and lazily in `getVehicles` (60 s cache per identifier, run in a separate thread so the callback doesn't wait). `Security.ClaimSpawn` for reconnecting owners runs only on the forced triggers, never on garage open. Finding an online player by identifier uses the reverse map `Bridge.GetSourceByIdentifier` (in `bridge/cache.lua`).
- **Sync on load** (`Config.SyncFrameworkTables = true`): on `esx:playerLoaded` / `QBCore:Server:PlayerLoaded` (also fired by Qbox), the player's rows in `owned_vehicles` / `player_vehicles` are imported. Plates are normalized, garages are resolved with `Utils.ResolveGarageId`, rows go in with a batched `INSERT IGNORE`, and the same ESX type/job/stored rules as the migration apply. This way dealership purchases appear in the garage.
- **Export for dealerships:** `exports.mdp_garages:AddVehicle(owner, plate, model, props?, garageId?) -> ok, err?`. It validates the owner (string, 64 characters max), plate (rule above), model (`[%w_]`, 64 characters max) and props (table or JSON, 64 KB max), resolves the garage id, and inserts with `INSERT IGNORE` as GARAGED. Returns `true, nil|'exists'|'transferred'|'restored'` or `false, err` (`invalid_owner`, `invalid_plate`, `invalid_model`, `invalid_props`, `db_error`). `model` can be a name or a numeric hash.

## Restart and reconnect (server/persistence.lua)
**Retries** (R3-5): if recovery fails, it is retried after 2 s, 5 s and 10 s. After that a boxed console error explains the cause (for example a missing `mdp_vehicles` table means `sql/install.sql` hasn't been run, or ALTER permission is missing), the resource stays `not_ready`, and the console command **`mdp_recover`** re-runs recovery.

Nothing depends on memory from a previous run. Every state transition is a conditional `UPDATE … WHERE state = ?` with an affectedRows check. **Callbacks return `not_ready` until the steps below finish** (`MDP.Ready`). If recovery fails, callbacks stay disabled and the error is printed. On start (`MySQL.ready`):
0. Check that `mdp_vehicles` exists, then run idempotent schema upgrades for older databases. These include `UNIQUE(owner, config_id)` on `mdp_private_garages`; legacy empty `config_id` values are filled with `legacy_<id>` first (R3-6). The upgrades add: missing `parked_at`, `vtype`, `channel` (and the `needs_review` ENUM value), `config_id` and `mdp_fine_invoices` are added after checking `information_schema`.
1. **Reconciliation with live entities** (R4-1, R4-2, R5-3). For every row in state 0 or 2, the server looks in `GetAllVehicles()` for entities with the same normalized plate **and** matching model hash (`Utils.UniqueWorldVehicle`), whether or not they carry our state bag (for example a dealership car after `restart mdp_garages`). A vehicle is adopted **only if exactly one** entity matches. With duplicates, none is adopted: the case is logged and treated as "no entity found", and the duplicates are left in the world (not deleted, and excluded from orphan cleanup).
   - **Found → adopted**: state bag `mdp_plate` plus `Security.TrackSpawn` (owner nil until `ClaimSpawn` on reconnect). Then, for state 0:
     - `OnRestartOutVehicles='garage'` with an empty vehicle: health saved, state 1 in `DefaultGarage`, entity deleted. **If the vehicle is occupied, the `'park'` logic applies instead** (R5-2).
     - `'park'` (default) with an empty vehicle: state 2 at the entity's **current** position (the entity stays).
     - `'park'` with someone inside: stays OUT, tracked.
     - State 2 rows stay parked and tracked.
   - **Not found**: state 0 → **GARAGED in `DefaultGarage`** in both modes, since a car without an entity would be stuck. State 2 rows are left unchanged (the takeOut safety net spawns them).
   - Our tagged entities (`mdp_plate`) whose row is no longer 0/2 are deleted as orphans, but only when empty.
   - All transitions are conditional (`WHERE plate=? AND state=?`).
2. *(merged into 1)*
3. The spawn registry (`Security.TrackSpawn`) and plate locks start empty. World-parked cars (state 2) are respawned by the proximity spawner from the DB.
4. Fines left at `paid=2` (CHARGING) after a crash are **not** reset, because the money may already have been taken. They move to `channel='needs_review'` (paid=0) with a console log so an admin can resolve them with `/mdp_finereview <id> paid|void`.
5. The schema version is checked, then `MDP.Ready = true`, then connected players are synced.
On `onResourceStop`, positions of live vehicles are saved (they stay OUT, and the next start converts them). Disconnects are handled by `Config.OnDisconnect` (see below).

## Vehicle types
`mdp_vehicles.vtype` is one of `automobile|bike|boat|heli|plane` (`Constants.VehicleTypes`) and is passed to `CreateVehicleServerSetter` on `takeOut`.
- **Resolution on store**, in priority order:
  1. `Config.VehicleTypes[model]` override.
  2. The server-side native `GetVehicleType(entity)`, mapped (quadbike and amphibious → automobile, submarine → boat, blimp → heli).
  3. The client's optional class hint `vclass` (from `GetVehicleClass`): 8 or 13 → bike, 14 → boat, 15 → heli, 16 → plane, anything else → automobile.
  4. `automobile`.
  The server validates the result against the whitelist.
- **Garages** declare `types = {'automobile', ...}` (missing = automobile only). `takeOut` and `storeVehicle` refuse a mismatch with `wrong_vehicle_type` (locale `err_wrong_vehicle_type`). `getVehicles` omits garaged vehicles whose type the garage can't hold, while still listing out/parked/impounded ones for status. Each `Vehicle` carries a `vtype` field.
- Migration and sync: ESX `type` boat/airplane/helicopter map to boat/plane/heli; QB rows default to automobile; `Config.VehicleTypes` overrides apply.

## Disconnect policy (`Config.OnDisconnect`)
`server/security.lua` owns `playerDropped`. It carries the player's rate limits for 30 s, releases their locks, and keeps their spawned vehicles tracked with owner `nil`. It then calls the hook **`Security.OnPlayerDropped(src, identifier, plates, reason)`**, which we implement in `server/persistence.lua`; we have no `playerDropped` handler of our own for vehicles.

Notify mapping: `Bridge.Notify` maps types for ox_lib (`info`/`primary` → `inform`, `warn` → `warning`). `Config.Notify='framework'` resolves to the started core's adapter.

If the plate lock is busy (for example a takeOut in progress), the policy is logged and retried every 2 s, up to 5 attempts (R3-7).

For each listed plate the player was **driving** (seat -1; if the ped is already gone, a vehicle with no driver counts), the policy runs inside `Security.WithLock(plate, 0, fn)` with atomic `UPDATE … WHERE plate=? AND state=0`:
| value | effect |
|---|---|
| `keep` (default) | state 2 at the vehicle's position, `parked_at=NOW()`; coords, heading and health (server natives) saved; the entity stays tracked (owner nil) |
| `garage` | state 1 in `Config.DefaultGarage`, health saved, entity deleted and untracked. **If anyone other than the dropping player is inside, `keep` applies instead** (R5-2); the same goes for `impound` |
| `impound` | state 3 in `Config.DefaultImpound`, plus an `mdp_impound` row using `Config.ImpoundReasons[Config.DisconnectImpoundReason]` (fee and hours computed server-side), entity deleted |

- **Timeout (optional):** `Config.Security.despawnOnDropMs`. Unclaimed vehicles after the timeout trigger `Security.OnDroppedVehicleTimeout(plate, netId, identifier)`, which saves the vehicle and sends it to `DefaultGarage`, but only if it's empty. It's disabled by default because it would also garage `keep` cars.
- **Reconnect:** on player load, the owner's vehicles in state 0/2 that are still tracked are handed back with `Security.ClaimSpawn(plate, src)`.
- **Identifier inside playerDropped:** ESX, QB and Qbox drop their player object in their own `playerDropped` handlers, and handler order between resources is undefined. So `bridge/cache.lua` wraps `Bridge.GetIdentifier` with a per-source cache (filled on player load and on every successful lookup, cleared 35 s after the drop). Security's rate-limit carry and the hook therefore always get the identifier.

## Garages and zones
Public, impound and private garage entrances are **ox_lib zones** (`lib.zones.sphere`/`box`) created client-side from shared config. Entering a zone shows a `lib.showTextUI` prompt, and the interaction opens the NUI. The server never trusts the zone: it re-checks distance against server config coords (10 m).

## World persistence (proximity spawn)
- Vehicles in state `PARKED_WORLD` (2) keep `coords`/`heading` in the DB. Limits: `Config.MaxWorldParkedPerPlayer = 5` and `Config.MaxWorldParkedServer = 150`. Both are checked server-side before an `OUT → PARKED_WORLD` change.
- A server loop checks player positions. When any player is within `Config.WorldSpawnRadius` (150 m) of a parked car that has no live entity, the **server** creates it with `CreateVehicleServerSetter(model, 'automobile', x, y, z, h)`, then sets the plate and state bag and broadcasts props for the clients to apply. When no player is within the radius plus some margin, the server saves its state and deletes the entity.
- **Single spawn owner:** only the server spawns persistent vehicles. The entity registry is keyed by plate (`Security.TrackSpawn` / `GetSpawnedEntity`). Every spawn runs inside `Security.WithLock(plate, src, fn, ...)` and first checks `GetSpawnedEntity(plate)`, which prevents duplicates. Clients never call `CreateVehicle` for owned cars.

**Limits.** When `MaxWorldParkedPerPlayer` or `MaxWorldParkedServer` is reached, `parkWorld` is refused with `{ok=false, error='world_limit'}` and a notification (`world_limit_player` / `world_limit_server`, en/es). If `Config.AutoImpoundOldest = true` (default false), hitting the **global** limit instead moves the oldest `PARKED_WORLD` car to state 3 with an `mdp_impound` row. The per-player limit always refuses.

**Saving.** A car is written to the DB (1) when it is parked (`parkWorld`/`storeVehicle`), (2) when its driver leaves it (`syncWear` sent on exit, carrying coords from the server entity), and (3) every `Config.SaveInterval` (5 min), for **dirty** vehicles only. Each server-tracked entity has a dirty flag, set when wear/coords change and cleared after the save.

**Despawn hysteresis.** A car spawns when any player is within `WorldSpawnRadius` (150 m). It is saved and despawned only when no player is within `WorldSpawnRadius + Config.DespawnMargin` (200 m). The gap stops spawn/despawn flapping at the edge.

**Example garages.** `Config.Garages` contains `public:legion`, `public:pillbox` and `public:sandy`, each with `label`, `coords`, `radius` (ox_lib zone) and `spawns` (vec4 with heading). `Config.DefaultGarage = 'public:legion'` is used by the migration and as a fallback.

## Keys
`qb-vehiclekeys` works **by plate** on both client and server (`GiveKeys(id, plate)`, `HasKeys(plate)`), so the keys bridge interface (`Bridge.Keys`) is plate-based: adapters receive a normalized plate (`Utils.NormalizePlate`), never an entity or netId. `mdp_vehicle_keys` stays the authoritative record, and the keys resource only mirrors physical access.

## Fines
Fines go through the **billing adapter** (`Bridge.Billing.Call('SendBill', …)`; see [integrations.md](integrations.md)). A row is always written to `mdp_fines` as an internal record and fallback: if no billing resource is present or the call fails, the fine stays in `mdp_fines` and is paid via `mdp_garages:payFine`. `Config.BlockOnUnpaidFines` (default `false`) together with `Config.UnpaidFinesThreshold` (count of unpaid `mdp_fines` rows) blocks `takeOut` when enabled.

**Channels** (`mdp_fines.channel`, `Constants.FineChannel`, chosen by `Bridge.Billing.IssueFine`):
| channel | When | Payment path |
|---|---|---|
| `invoice` | the billing adapter supports fines (`SupportsFines ~= false`), `SendBill` returned true, and `Bridge.BillingCommon.HasInvoice(fineId)` is true | paid in the resource; paid hook → `Bridge.BillingCommon.OnPaid` → `MarkFinePaid` |
| `internal` | no adapter; the adapter has `SupportsFines == false` (**okokBilling is not used for fines**); or `SendBill` failed and no invoice is linked | `mdp_garages:payFine` / `/mdp_payfine` |
| `needs_review` | `SendBill` returned true but no invoice got linked (logged to the console) | blocked for players. Staff resolve it with `/mdp_finereview <id> paid\|void` (`server/fine_review.lua`, Integrations; the manifest loads it through a glob that tolerates its absence) |
| `external` | kept in the ENUM, **unused for fines** | – |

`mdp_fines.paid` (`Constants.FineStatus`): `0` = unpaid, `1` = paid, `2` = **CHARGING** (internal payment in progress; leftovers become needs_review on start), `3` = voided. `Config.UnpaidFinesThreshold` counts only `paid = 0 AND channel IN ('internal','invoice')`, so **needs_review fines don't block**.

Adapter choice: the first started adapter in PRIORITY order (**esx_billing, then qb-phone, then okokBilling**) with `SupportsFines ~= false`; okokBilling is never used for fines. `MarkFinePaid` logs every refusal, and on a DB error it moves the fine to needs_review. `Config.OkokTrustServerEvent = false` covers okok fees only (it's unverified whether okok accepts `CreateCustomInvoice` server-side).

**Issuing:** `Bridge.Billing.IssueFine(officerSrc, targetSrc, plate, owner, amount, reason, issuedBy, society) -> fineId, channel`. It validates the amount, plate and owner, sanitizes `reason`/`issued_by` (255/64 characters), inserts the row with its channel, then calls `SendBill(..., meta={fineId})`.

**Payment hook (adapter contract):** `adapter.SupportsPaidHook = true`. When paid, the adapter calls `Bridge.Billing.MarkFinePaid(fineId, source) -> boolean`, which is idempotent: `UPDATE mdp_fines SET paid=1 WHERE id=? AND paid=0` with an affectedRows == 1 check, firing `mdp_garages:server:finePaid` on true. Amounts from billing events are never used.

**Adapters present** (Integrations, see [integrations.md](integrations.md)): auto order is okokBilling, then esx_billing, then qb-phone.

**Internal payment** (`server/fines.lua`): the `mdp_garages:payFine` lib.callback `{fineId}` (schema int, RATE 2/2 s) and `/mdp_payfine <fineId>`.
1. The row must have `owner = Bridge.GetIdentifier(src)`, `paid = 0` and `channel = 'internal'`, with no linked invoice (`Bridge.BillingCommon.HasInvoice`). Otherwise the call fails with `external_invoice`. The amount is read **from the DB only** and checked with `Bridge.ValidAmount`.
2. Inside `Security.WithLock('fine:'..id, src, fn)`, the fine is **claimed as CHARGING** with `UPDATE … SET paid=2 WHERE id=? AND owner=? AND paid=0 AND channel='internal'`. The call continues only if affectedRows == 1.
3. `Bridge.RemoveMoney(src, 'bank', amount)`. On failure: `UPDATE … SET paid=0 WHERE id=? AND paid=2`. On success: `UPDATE … SET paid=1 WHERE id=? AND paid=2` and fire `mdp_garages:server:finePaid`.
4. Error codes are mapped to locale strings before they're shown to the player.

## Location visibility
The owner always receives `coords`. Key holders receive them only when `Config.KeyHoldersSeeLocation = true` (the default). Nobody else ever receives them. This is filtered server-side before the response is sent.

## Migration (sql/migrate.lua, optional)
It's off by default. It runs when `Config.Migration.Enabled = true` (once at start) or through the restricted command `mdp_migrate` (console, or ace `command.mdp_migrate`). It imports **only the detected framework's table** (`owned_vehicles` for ESX, `player_vehicles` for QB/Qbox) through `Vehicles.ImportFromFramework`, using multi-row `INSERT IGNORE` in batches of `Config.Migration.BatchSize` (500). The originals are never modified.
- ESX `type`: only types listed in `Config.Migration.VehicleTypes` are imported (cars by default).
- ESX `job`: non-empty rows (other than `civ`) are skipped when `SkipJobVehicles` is set.
- ESX `stored=0` maps to `Config.Migration.NotStored` (`garaged` or `impounded`).
- ESX `parking` is first mapped through `Config.ESXParkingMap[value]` (falling back to `public:<value>`), then goes through `Utils.ResolveGarageId`. QB `garage` goes through `Utils.ResolveGarageId` as `public:<garage>`. The same rules apply to sync on player load.
- QB `state=2` maps to IMPOUNDED.
- Skipped rows are counted by reason (`invalid_plate`, `type`, `job`, `no_owner`) and reported in the console.

## NUI contract
The UI is React + Untitled UI, built to `web/dist` (manifest: `ui_page 'web/dist/index.html'`, `files {'web/dist/index.html','web/dist/**/*'}`).

**Lua → NUI (SendNUIMessage)**
```
{ action = 'open',   view = 'list' | 'detail', data = OpenData, plate? = string, locale = UILocale }   -- plate: vehicle for the detail view
{ action = 'update', data = table, view? = 'list' | 'detail', plate? = string }   -- partial: data is MERGED onto the current state (only the keys sent change)
{ action = 'close' }
```
`OpenGarageUI(view, data)` sends `open` and calls `SetNuiFocus(true, true)`. **Closing is NUI-only**: the NUI handles ESC and calls `close`. While the UI is open, the client runs a per-frame loop that only disables the pause-menu controls (199, 200), and the loop exits when the UI closes. There is no ESC handling in Lua. Pause-menu blocking continues for about 250 ms after close so the closing ESC can't open the pause menu. Stuck-focus recovery (checked every 500 ms, not ESC-based) calls `UI.Close()`, which also hides the NUI. `OpenGarageUI` refuses to open without `data.garage.id`.

`UILocale` is a flat `{ [key] = string }` table built by `Utils.UILocale()` from the active locale's `ui` sub-table, with English filling any missing key. Keys: `title, close, back, vehicles, search, empty, loading, take_out, details, retired_section, retired_hint, state_out, state_garaged, state_parked, state_impounded, state_retired, state_unknown, select_vehicle, plate, model, fuel, engine, body, mileage, location, owner, key_holder, impound_fee, release_after, error`, plus **`err_<code>` for every error code** listed below. The NUI shows `locale['err_'..code]`, falling back to its English table. The NUI must not hardcode any user-facing text.

**Object shapes**
```
OpenData = { garage: Garage, vehicles: Vehicle[] }

Garage = {
  id: string            -- 'public:<id>' | 'private:<id>' | 'impound:<id>'
  kind: string          -- 'public' | 'private' | 'impound'
  label: string
  types?: string[]      -- accepted vehicle types (server config)
  slots?: number        -- private garages only
  used?: number         -- private garages only
  fee?: number          -- impound only; display only, server recomputes
}

Vehicle = {
  plate: string         -- normalized, 1-8 chars [A-Z0-9 ]
  model: string         -- spawn name
  label: string         -- display name
  state: number         -- 0=out, 1=garaged, 2=parked_world, 3=impounded, 4=retired (phase 7). 5=removed is never sent
  fuel: number          -- 0-100
  engine: number        -- 0-1000
  body: number          -- 0-1000
  mileage: number       -- in Config.MileageUnit
  mileage_unit: string  -- 'km' | 'mi'
  vtype: string         -- 'automobile' | 'bike' | 'boat' | 'heli' | 'plane'
  garage_id: string|null
  is_owner: boolean     -- false = key holder
  coords?: { x: number, y: number, z: number }  -- only if owner, or key holder with Config.KeyHoldersSeeLocation
  impound?: { reason: string, fee: number, release_after: number|null }  -- unix seconds; state 3 only
}
```

**Take-out rules (server and UI must agree):** `canTakeOut` = state **1 or 2** (2 is the safety net until the phase 1 streamer). State **3** (impounded) is **shown only**: `getVehicles` also works in `impound:*` garages for display, `takeOut` refuses with `impounded`, and the paid release at the lot comes in phase 5 (`releaseImpound`).

**Retired vehicles (state 4, phase 7):** they are listed in a separate **'Retired'** section with no take-out button (recovery is through the phone app). `mdp_garages:takeOut` refuses them with `retired`.

**Server responses:** `mdp_garages:getVehicles` returns `{ok=true, data=Vehicle[]}` and `mdp_garages:takeOut` returns `{ok=true, data={netId}}`, or `{ok=false, error}` (implemented in `server/garages.lua`). The client passes them straight to `cb(res)`.

**NUI → Lua (RegisterNUICallback); all responses are `{ ok: boolean, error?: string, data?: any }`**
| Callback | Request | Response `data` | Lua side |
|---|---|---|---|
| `close` | `{}` | – | `SetNuiFocus(false,false)`, `cb({ok=true})` |
| `getVehicles` | `{ garage_id: string }` | `Vehicle[]` | validates `Utils.IsValidGarageId`, proxies `lib.callback.await('mdp_garages:getVehicles')` |
| `takeOut` | `{ plate: string, garage_id: string }` | `{ netId: number }` | normalizes and validates the plate and garage_id, proxies `mdp_garages:takeOut`, closes the UI on success |

### Error codes (single source of truth)
This list is definitive. `Constants.ErrorCodes` (Lua), the locale keys `ui.err_<code>` (en/es) and the NUI's `NUI_ERROR_CODES` / `i18n.tsx` must all match it exactly.

- `invalid_request`
- `invalid_garage`
- `wrong_garage_kind`
- `unknown_garage`
- `wrong_garage`
- `server_error`
- `rejected`
- `not_found`
- `not_owner`
- `too_far`
- `rate_limited`
- `locked`
- `already_out`
- `retired`
- `impounded`
- `no_spawn`
- `spawn_failed`
- `unpaid_fines`
- `insufficient_funds`
- `world_limit`
- `external_invoice`
- `not_ready`
- `wrong_vehicle_type`
- `plate_unresolved`
- `invalid_state`
- `not_in_vehicle`
- `clone_detected`
- `not_tracked`
- `invalid_source`
- `already_paid`
- `invalid_amount`
- `fine_not_found`
- `in_use`
- `vehicle_moved`
- `occupied`
- `invalid_props`
- `timeout`

`timeout` is **NUI-only**: the NUI generates it when a callback doesn't answer, and the server never sends it. `impounded` applies to state 3 (paid release is phase 5), and `fine_not_found` comes from payFine. On the client, `Utils.ErrorCode` strips any `:<detail>` suffix (for example `plate_unresolved:no_entity` becomes `plate_unresolved`) and maps undocumented codes, such as internal Security reasons like `job_denied` or `unknown_field`, to `rejected`. Notifications use `Utils.ErrorText(code)`, which reads `ui.err_<code>`. Prices and fees are never accepted from the NUI; the server computes them from config/DB.

## Events and callbacks (planned)
All request/response endpoints use **ox_lib `lib.callback`** only (there is no event fallback) and are registered through `Security.RegisterSecureCallback`. Validation codes:
- **OWN**: `Security.IsOwner(src, plate)` allows the owner or a key holder; **OWN!** means `Security.IsOwner(src, plate, false)`, owner only. The identifier always comes from `Bridge.GetIdentifier(src)`.
- **GAR**: `Utils.GetGarage(garage_id, kind)` must succeed (the garage exists and its kind matches) before anything else uses the garage.
- **DIST**: `Security.IsNear(src, serverCoords, max)`. 10 m for a garage (coords from `Utils.GetGarage(...).coords`) and 5 m for a vehicle (server entity from netId).
- **ATOM**: `Security.WithLock(plate, src, fn, ...)` + `UPDATE mdp_vehicles SET state=? WHERE plate=? AND state=?`, with ownership verified in the same transaction (owner from the DB row) with an `affectedRows == 1` check, plus `Security.TrackSpawn`.
- **RATE**: `opts.rateLimit`. Spawn/store 1/1 s, queries 5/10 s.
- **AMT**: price from server config only; integer >= 0 with a cap (`Bridge.ValidAmount`); `Bridge.GetMoney`/`RemoveMoney`.
- **JOB**: `opts.job = {names, minGrade, requireDuty?}` via `Security.HasJob`. On duty is required by default; `requireDuty = false` skips it.
- **NUI**: `opts.schema`, plate `^[A-Z0-9 ]{1,8}$` after normalizing, garage_id via `Utils.IsValidGarageId`, strings through `Security.V.sanitizeString`.

| Name | Type | Direction | Triggered by | Payload | Server validation |
|---|---|---|---|---|---|
| `mdp_garages:getVehicles` | lib.callback | C→S | NUI `getVehicles` | `{garage_id}` | RATE(5/10s), schema `garage_id=V.isGarageId`, GAR(`{public,private,impound}`; impound is display only), DIST(garage 10 m); returns only vehicles the player owns or holds keys for, coords filtered by the visibility rule |
| `mdp_garages:takeOut` | lib.callback | C→S | NUI `takeOut` | `{plate, garage_id}` | **Implemented.** not_ready guard, schema, RATE(1/s), GAR(`{public,private}`), DIST, `requireOwnership`, type check, fines threshold. State 1 in this garage, **or state 2 as a safety net** until the phase 1 proximity streamer (any garage). For state 2 with a live tracked entity: refused with **`in_use`** if any seat is occupied, or **`vehicle_moved`** if the entity is more than `Config.ParkedMoveTolerance` (5 m) from the stored coords; otherwise the entity is deleted first (R3-4). Inside `WithLock(plate, src, fn)`: conditional `UPDATE … WHERE plate=? AND state=<read state>` (affectedRows == 1), `CreateVehicleServerSetter(Utils.ModelHash(model), vtype, …)`, rollback to state 1 on spawn failure, `TrackSpawn`. **Phase 1:** spawn via `MDP.Props.SpawnVehicle` (sets `mdp_plate` + `mdp_props` state bags, ox_fuel fuel server-side), then `Bridge.Keys.GiveKeys(src, veh)` once the entity exists. State 2 take-out is **kept** as a 'bring my car' feature (the streamer only spawns parked cars in place). |
| `mdp_garages:storeVehicle` | lib.callback | C→S | player in a garage zone ([E] as driver, `client/zones.lua`) | `{netId, garage_id, vclass?, props?, fuel?, mileage?}` (phase 1: props = `lib.getVehicleProperties`, fuel 0-100, mileage km) | **Implemented** (`server/garages.lua`). State 5 → `not_found`. RATE(1/s), schema, GAR(`{public,private}`), DIST(garage 10 m + vehicle 5 m). `resolvePlate` (`Security.PlateFromNetId`: entity must exist and be a vehicle, plate read and normalized server-side) → `data._plate`, `requireOwnership` on `data._plate`; model must match the DB; vtype resolved and checked against `garage.types`. Inside `WithLock(plate, src, fn)`: `UPDATE … WHERE state IN (0,2)` (affectedRows == 1) saving vtype and server-read health, `UntrackSpawn`, delete entity The player must be inside the vehicle (`not_in_vehicle`) **as the driver and alone**: any other occupant gives `occupied` (R3b-2). netId is normalized with `math.tointeger` (R4-3). **Anti-clone (R3-1):** if a *different* tracked entity has the plate, this one is a clone, so it is deleted and rejected (`clone_detected`). If **no** entity is tracked (spawned by a dealership or another script), the vehicle is accepted when DB ownership, model hash and **state 0 (OUT)** all match, and it is tracked at that point. Otherwise `not_tracked`. The model is compared with `Utils.ModelHash`. **Phase 1:** props go through `Security.SanitizeProps(props, dbRow+entityModel)` (fallback until it exists: table, JSON <= 16 KB, model = entity, plate overwritten; TODO) → `invalid_props`; fuel from `Bridge.Fuel.GetFuel(veh)` when `Bridge.Fuel.ServerCapable()` (ox_fuel), else client value clamped 0-100 and <= DB fuel + 2; mileage never decreases, max +`Config.MaxMileageDeltaKm` per store; engine/body read server-side; props saved with `COALESCE(?, props)`. |
| `mdp_garages:parkWorld` | lib.callback | C→S | player parks on the street | `{netId}` | RATE(1/s), DIST(vehicle 5 m), `resolvePlate` → `data._plate`, OWN, world limits (refused with `world_limit` + notify), `WithLock(plate, src, fn)`, ATOM(0→2), sets `parked_at`, coords/heading read from the server entity |
| `mdp_garages:client:applyProps` | event | S→C | server after spawning a persistent car | `{netId, props}` | server-originated; client only applies props |
| `mdp_garages:syncWear` | lib.callback | C→S | client every N min while driving / on exit | `{netId, mileageDelta}` | RATE, src is the driver, `resolvePlate` → `data._plate`, OWN/key, delta clamped by max plausible speed × time. **Health is read server-side** (`GetVehicleEngineHealth`/`GetVehicleBodyHealth` on the server entity), never from the client; fuel via `Bridge.Fuel` |
| `mdp_garages:giveKey` | lib.callback | C→S | owner shares a key | `{plate, target}` | schema, RATE, OWN! (`IsOwner(src, plate, false)`), target player within 5 m, max keys per vehicle; `Bridge.Keys` adapter |
| `mdp_garages:removeKey` | lib.callback | C→S | owner revokes a key | `{plate, holder}` | schema, RATE, OWN! |
| `mdp_garages:issueFine` | lib.callback | C→S | police / parking warden | `{netId, reason}` | JOB (`requireDuty` default true), DIST(vehicle), `resolvePlate` → `data._plate`, amount from config (AMT), RATE; `Bridge.Billing.IssueFine` |
| `mdp_garages:payFine` | lib.callback | C→S | player / phone app | `{fineId}` | RATE, fine owner == identifier, AMT, `UPDATE … WHERE id=? AND paid=0` (ATOM) |
| `mdp_garages:towVehicle` | lib.callback | C→S | tow job | `{netId}` | RATE(1/s), JOB (on duty), DIST(vehicle), `resolvePlate` → `data._plate`, `WithLock(plate, src, fn)`, ATOM(→3), insert into `mdp_impound` |
| `mdp_garages:impoundVehicle` | lib.callback | C→S | police | `{netId, reasonId, garage_id='impound:<id>'}` | RATE(1/s), JOB+minGrade (on duty), GAR(`impound`), DIST(vehicle), `resolvePlate` → `data._plate`, **fee and release_after computed server-side from `Config.ImpoundReasons[reasonId]`** (client sends no amounts), `WithLock`, ATOM(→3) |
| `mdp_garages:releaseImpound` | lib.callback | C→S | owner at the impound lot | `{plate, garage_id='impound:<id>'}` | RATE, GAR(`impound` only), DIST(lot), OWN!, `release_after <= NOW()`, fee from `mdp_impound` via RemoveMoney (AMT), `WithLock(plate, src, fn)`, ATOM(3→1) |
| `mdp_garages:client:setGps` | event | S→C | server after an impound or on request | `{x,y,z}` | server-originated |
| `mdp_garages:buyPrivateGarage` | lib.callback | C→S | player at a property | `{config_id}` | schema, RATE(1/s), private-garage config lookup, DIST, price from config (AMT). `INSERT` first (UNIQUE(owner, config_id) rejects duplicates), then charge; if the charge fails, `DELETE` the row, all inside a per-owner lock |
| `mdp_garages:enterPrivateGarage` | lib.callback | C→S | player at an entrance | `{garage_id}` | RATE(1/s), GAR(`private`), owner or allowed player, DIST(entrance), routing bucket set server-side |
| `mdp_garages:phone:getVehicles` | lib.callback | C→S | phone app | `{}` | RATE(5/10s), OWN/key vehicles only, coords per visibility rule |
| `mdp_garages:client:notify` | event | S→C | last-resort Bridge.Notify fallback | `msg, type` | server-originated |

Rule: no client→server **event** may change state or money.

## Open questions
1. The example garage and impound coords are approximate and need checking in-game.
2. The private-garage config shape and the server-side `Utils.PrivateGarageLookup` are still to be designed.
3. Phase 1 (QA N6): keys on takeOut, applying fuel/engine/body/props through a state bag and client applier, the proximity streamer for state 2 (which will retire the takeOut safety net), and a client store trigger.
4. Should vehicles deleted from the framework table be retired automatically during sync? Only owner changes propagate today.
5. `Config.OkokTrustServerEvent` needs verifying against a real okokBilling install.


## Phase 1 contract
- `mdp_garages:storeVehicle` (C→S lib.callback): `{garage_id, netId, props?, vclass?, fuel?, mileage?}`; **no plate** (resolved server-side) → `{ok, error?}`.
- `mdp_garages:parkWorld` (C→S lib.callback, client `/mdp_park`): `{netId, props?, vclass?, fuel?, mileage?}`, no plate. RATE 1/s, `resolvePlate`, `requireOwnership`, vehicle empty and player within `MaxVehicleDistance`, state must be 0, model = DB, anti-clone, limits (`world_limit`, notified; `AutoImpoundOldest` frees the oldest state-2 car for the global limit only), props via `SanitizeProps`, fuel/mileage rules as store. Inside `WithLock`: `UPDATE … state=2, coords, heading, health, parked_at WHERE state=0`, doors locked, handed to the streamer.
- `mdp_garages:takeOut`: unchanged payload; keys given after the entity exists.
- State bag `mdp_props`: `{props, fuel, engine, body}` plus `fuelOnClient`, `mileage`.

## Phase 1: props, spawn and parked streamer
**State bag `mdp_props`** (set by the server on every spawn, replicated): `{ props: table|nil, engine: number, body: number, fuel: number, fuelOnClient: boolean, mileage: number (km) }`. `client/props.lua` applies it only on the **network owner** of the entity, retrying `NetworkRequestControlOfEntity` until control (max 10 s): `lib.setVehicleProperties`, engine/body health, and fuel via `Bridge.Fuel.Call('SetFuel')` when `fuelOnClient` (LegacyFuel/cdn-fuel/native). ox_fuel is set server-side (`Bridge.Fuel.SetFuel`). Limitation: if the owner changes before applying, the new owner does not re-apply (open question).

**Odometer:** the client accumulates km while driving (base = `mdp_props.mileage`, teleports > 200 m/s ignored) and sends it with `storeVehicle`; the server only accepts increases up to `Config.MaxMileageDeltaKm`.

**Parked streamer** (`server/streamer.lua`): registry of state-2 rows with coords (DB refresh every `Config.StreamerRefreshMs`, plus `MDP.Streamer.Track/Forget` on transitions; refreshed when `MDP.Ready`). Every `Config.StreamerTickMs` (1.5 s):
- no tracked entity and nearest player <= `WorldSpawnRadius` (150) → spawn in its own thread inside `WithLock(plate)`, re-checking `GetSpawnedEntity` and `state = 2` in the DB; `MDP.Props.SpawnVehicle` → `TrackSpawn` (server is the single spawn owner, so never two entities per plate). Doors locked.
- tracked entity, empty, nearest player > `WorldSpawnRadius + DespawnMargin` (200) → save coords/heading/engine/body if changed (`UPDATE … WHERE state = 2`), `UntrackSpawn`, delete. Props cannot be read server-side; they stay as last stored.
- tracked entity with a driver → `UPDATE state = 0 WHERE state = 2` and `Security.ClaimSpawn(plate, driverSrc)`; leaves the registry. Who can drive is up to the keys resource (doors locked).
Restart: recovery (adoption rules R5-3/R6-1) runs first; adopted state-2 entities stay tracked and the streamer just manages them. **R6-1:** an OUT row with >= 2 matching world entities stays OUT (logged), never GARAGED.
