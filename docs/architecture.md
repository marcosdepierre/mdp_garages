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
| `mdp_vehicles` | one row per owned vehicle: props, coords JSON, heading, `state` TINYINT, fuel, engine, body, mileage, garage_id | UNIQUE plate; owner, state, garage_id |
| `mdp_vehicle_keys` | shared keys | UNIQUE(plate, holder); holder; FK plate CASCADE |
| `mdp_private_garages` | purchased garages with interior; `config_id` = property key from server config | owner; UNIQUE(owner, config_id) stops a double click from buying twice; UNIQUE(owner, label) |
| `mdp_impound` | impound records (fee, release_after, location, released) | plate, released; FK plate CASCADE |
| `mdp_fines` | fines; `channel` ENUM internal/invoice/external/needs_review, `paid` 0/1/2/3 (unpaid/paid/claiming/voided) | plate, owner, paid; FK plate CASCADE |
| `mdp_fine_invoices` | billing invoice → fine mapping (`provider`, `invoice_id`, `fine_id`), written by `BillingCommon.Link` and read by `BillingCommon.OnPaid` (bridge/billing/_common.lua, which also creates it at runtime) | PK(provider, invoice_id); fine_id `INT UNSIGNED` FK → `mdp_fines(id)` ON DELETE CASCADE |
| `mdp_schema_version` | applied schema versions (currently 1); future phases add idempotent ALTERs keyed by version. The server warns at start if the version is lower than `Constants.SchemaVersion` | PK(version) |

`state` constants (`shared/constants.lua`): `Constants.VehicleState`: `0=OUT, 1=GARAGED, 2=PARKED_WORLD, 3=IMPOUNDED, 4=RETIRED`.

`RETIRED` (4) is **phase 7, schema only for now**: a world-parked car left inactive for `Config.InactivityRetireHours` (72 h, measured from `mdp_vehicles.parked_at`, indexed by `(state, parked_at)`) gets removed from the world. It can be recovered from the phone app. No logic exists yet.

## Shared helpers (shared/utils.lua)
- `Utils.NormalizePlate(v)`: trim + upper.
- `Utils.NormalizePlate` also collapses internal whitespace to a single space (`'A  B'` becomes `'A B'`).
- `Utils.IsValidPlate(v)`: after normalizing, **length 1–8 (`Config.PlateMaxLength`), characters `[A-Z0-9 ]` only**. Equivalent to `^[A-Z0-9 ]{1,8}$`. This matches GTA, which truncates plates to 8 characters. The DB column stays `VARCHAR(12)` for headroom.
- `Utils.ParseGarageId(v)` / `Utils.IsValidGarageId(v)`: the single validator for `garage_id`. It must be `public:<id>`, `private:<id>` or `impound:<id>`, where `<id>` is `[A-Za-z0-9_-]` and 1–32 characters. Every garage_id coming from the client or NUI goes through it, and the server then resolves the id against server config or the DB.
- `Utils.ResolveGarageId(garageId, plate) -> id, remapped`: used wherever a stored garage_id is loaded and in migrate.lua. An invalid format, or a `public:` id missing from `Config.Garages`, is remapped to `Config.DefaultGarage` with a console warning that shows the plate and the original value. `private:`/`impound:` ids are checked by format only.
- `Utils.GetGarage(id, expectedKind) -> garage | nil, err`: **every** garage lookup and `distance.getCoords` must go through it. It confirms the garage exists (public/impound in `Config.Garages`; private through the server-set `Utils.PrivateGarageLookup(id)` DB resolver) and that its kind matches the action. Impound garages are only valid for `releaseImpound`; public/private garages are valid for `takeOut`/`storeVehicle`/`getVehicles`. Errors: `invalid_garage`, `wrong_garage_kind`, `unknown_garage`.
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

Other helpers: `Security.WithLock(plate, src, fn, ...)` (per-plate lock, released even if `fn` errors) / `Security.Lock(plate, src)` / `Unlock(plate)`, `Security.IsKeyHolder`, `Security.TrackSpawn` / `UntrackSpawn` / `GetSpawnedEntity` (spawn registry by plate), `Security.RateLimit`, `Security.V.*` validators, `Security.LogReject`, and the `Security.OnSuspicious` hook.

## Source of truth and framework tables
`mdp_vehicles` is the source of truth. Framework tables are only read, never written.
- **Sync on load** (`Config.SyncFrameworkTables = true`): on `esx:playerLoaded` / `QBCore:Server:PlayerLoaded` (also fired by Qbox), the player's rows in `owned_vehicles` / `player_vehicles` are imported. Plates are normalized, garages are resolved with `Utils.ResolveGarageId`, rows go in with a batched `INSERT IGNORE`, and the same ESX type/job/stored rules as the migration apply. This way dealership purchases appear in the garage.
- **Export for dealerships:** `exports.mdp_garages:AddVehicle(owner, plate, model, props?, garageId?) -> ok, err?`. It validates the owner (string, 64 characters max), plate (rule above), model (`[%w_]`, 64 characters max) and props (table or JSON, 64 KB max), resolves the garage id, and inserts with `INSERT IGNORE` as GARAGED. Errors: `invalid_owner`, `invalid_plate`, `invalid_model`, `invalid_props`, `plate_exists`, `db_error`.

## Restart and reconnect (server/persistence.lua)
Nothing depends on memory from a previous run. On start (`MySQL.ready`):
1. Leftover entities of ours (state bag `mdp_plate`, which happens on a resource restart) have their coords/heading saved to their state-0 row, then they are deleted.
2. Atomic SQL: with `Config.OnRestartOutVehicles = 'park'`, `UPDATE … SET state=2, parked_at=NOW() WHERE state=0 AND coords IS NOT NULL`. Then, in both modes, `UPDATE … SET state=1, garage_id=Config.DefaultGarage WHERE state=0`.
3. The spawn registry (`Security.TrackSpawn`) and plate locks start empty. World-parked cars (state 2) are respawned by the proximity spawner from the DB.
4. The schema version is checked.
On `onResourceStop`, positions of live vehicles are saved (they stay OUT, and the next start converts them). A disconnecting player's car stays in the world as OUT until the next restart (phase 1 may add `Config.OnDisconnect`).

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
| `invoice` | the billing adapter supports fines (`SupportsFines ~= false`), `SendBill` returned true, and `BillingCommon.HasInvoice(fineId)` is true | paid in the resource; paid hook → `BillingCommon.OnPaid` → `MarkFinePaid` |
| `internal` | no adapter; the adapter has `SupportsFines == false` (**okokBilling is not used for fines**); or `SendBill` failed and no invoice is linked | `mdp_garages:payFine` / `/mdp_payfine` |
| `needs_review` | `SendBill` returned true but no invoice got linked (logged to the console) | blocked for players. Staff resolve it with `/mdp_finereview <id> paid\|void` (`server/fine_review.lua`, Integrations; the manifest loads it through a glob that tolerates its absence) |
| `external` | kept in the ENUM, **unused for fines** | – |

`mdp_fines.paid` (`Constants.FineStatus`): `0` = unpaid, `1` = paid, `2` = claiming (internal payment in progress; reset to 0 on resource start), `3` = voided. `Config.UnpaidFinesThreshold` counts **only `paid = 0`**.

**Issuing:** `Bridge.Billing.IssueFine(officerSrc, targetSrc, plate, owner, amount, reason, issuedBy, society) -> fineId, channel`. It validates the amount, plate and owner, sanitizes `reason`/`issued_by` (255/64 characters), inserts the row with its channel, then calls `SendBill(..., meta={fineId})`.

**Payment hook (adapter contract):** `adapter.SupportsPaidHook = true`. When paid, the adapter calls `Bridge.Billing.MarkFinePaid(fineId, source) -> boolean`, which is idempotent: `UPDATE mdp_fines SET paid=1 WHERE id=? AND paid=0` with an affectedRows == 1 check, firing `mdp_garages:server:finePaid` on true. Amounts from billing events are never used.

**Adapters present** (Integrations, see [integrations.md](integrations.md)): auto order is okokBilling, then esx_billing, then qb-phone.

**Internal payment** (`server/fines.lua`): the `mdp_garages:payFine` lib.callback `{fineId}` (schema int, RATE 2/2 s) and `/mdp_payfine <fineId>`.
1. The row must have `owner = Bridge.GetIdentifier(src)`, `paid = 0` and `channel = 'internal'`, with no linked invoice (`BillingCommon.HasInvoice`). Otherwise the call fails with `external_invoice`. The amount is read **from the DB only** and checked with `Bridge.ValidAmount`.
2. Inside `Security.WithLock('fine:'..id, src, fn)`, the fine is **claimed** with `UPDATE … SET paid=2 WHERE id=? AND owner=? AND paid=0 AND channel='internal'`. The call continues only if affectedRows == 1.
3. `Bridge.RemoveMoney(src, 'bank', amount)`. On failure: `UPDATE … SET paid=0 WHERE id=? AND paid=2`. On success: `UPDATE … SET paid=1 WHERE id=? AND paid=2` and fire `mdp_garages:server:finePaid`.
4. Error codes are mapped to locale strings before they're shown to the player.

## Location visibility
The owner always receives `coords`. Key holders receive them only when `Config.KeyHoldersSeeLocation = true` (the default). Nobody else ever receives them. This is filtered server-side before the response is sent.

## Migration (sql/migrate.lua, optional)
It's off by default. It runs when `Config.Migration.Enabled = true` (once at start) or through the restricted command `mdp_migrate` (console, or ace `command.mdp_migrate`). It imports **only the detected framework's table** (`owned_vehicles` for ESX, `player_vehicles` for QB/Qbox) through `Vehicles.ImportFromFramework`, using multi-row `INSERT IGNORE` in batches of `Config.Migration.BatchSize` (500). The originals are never modified.
- ESX `type`: only types listed in `Config.Migration.VehicleTypes` are imported (cars by default).
- ESX `job`: non-empty rows (other than `civ`) are skipped when `SkipJobVehicles` is set.
- ESX `stored=0` maps to `Config.Migration.NotStored` (`garaged` or `impounded`).
- ESX `parking` and QB `garage` go through `Utils.ResolveGarageId`.
- QB `state=2` maps to IMPOUNDED.
- Skipped rows are counted by reason (`invalid_plate`, `type`, `job`, `no_owner`) and reported in the console.

## NUI contract
The UI is React + Untitled UI, built to `web/dist` (manifest: `ui_page 'web/dist/index.html'`, `files {'web/dist/index.html','web/dist/**/*'}`).

**Lua → NUI (SendNUIMessage)**
```
{ action = 'open',   view = 'list' | 'detail', data = OpenData }
{ action = 'update', data = table, view? = 'list' | 'detail' }   -- partial: data is MERGED onto the current state (only the keys sent change)
{ action = 'close' }
```
`OpenGarageUI(view, data)` sends `open` and calls `SetNuiFocus(true, true)`. ESC is handled by the NUI, which calls `close`; the client also has an ESC/pause-menu safety net.

**Object shapes**
```
OpenData = { garage: Garage, vehicles: Vehicle[] }

Garage = {
  id: string            -- 'public:<id>' | 'private:<id>' | 'impound:<id>'
  kind: string          -- 'public' | 'private' | 'impound'
  label: string
  slots?: number        -- private garages only
  used?: number         -- private garages only
  fee?: number          -- impound only; display only, server recomputes
}

Vehicle = {
  plate: string         -- normalized, 1-8 chars [A-Z0-9 ]
  model: string         -- spawn name
  label: string         -- display name
  state: number         -- 0=out, 1=garaged, 2=parked_world, 3=impounded, 4=retired (phase 7)
  fuel: number          -- 0-100
  engine: number        -- 0-1000
  body: number          -- 0-1000
  mileage: number       -- in Config.MileageUnit
  mileage_unit: string  -- 'km' | 'mi'
  garage_id: string|null
  is_owner: boolean     -- false = key holder
  coords?: { x: number, y: number, z: number }  -- only if owner, or key holder with Config.KeyHoldersSeeLocation
  impound?: { reason: string, fee: number, release_after: number|null }  -- unix seconds; state 3 only
}
```

**Retired vehicles (state 4, phase 7):** they are listed in a separate **'Retired'** section with no take-out button (recovery is through the phone app). `mdp_garages:takeOut` refuses them with `retired`.

**Server responses:** `mdp_garages:getVehicles` returns `{ok=true, data=Vehicle[]}` and `mdp_garages:takeOut` returns `{ok=true, data={netId}}`, or `{ok=false, error}` (implemented in `server/garages.lua`). The client passes them straight to `cb(res)`.

**NUI → Lua (RegisterNUICallback); all responses are `{ ok: boolean, error?: string, data?: any }`**
| Callback | Request | Response `data` | Lua side |
|---|---|---|---|
| `close` | `{}` | – | `SetNuiFocus(false,false)`, `cb({ok=true})` |
| `getVehicles` | `{ garage_id: string }` | `Vehicle[]` | validates `Utils.IsValidGarageId`, proxies `lib.callback.await('mdp_garages:getVehicles')` |
| `takeOut` | `{ plate: string, garage_id: string }` | `{ netId: number }` | normalizes and validates the plate and garage_id, proxies `mdp_garages:takeOut`, closes the UI on success |

Error strings: `invalid_request`, `invalid_garage`, `wrong_garage_kind`, `unknown_garage`, `wrong_garage`, `server_error`, `rejected`, `not_found`, `not_owner`, `too_far`, `rate_limited`, `locked`, `already_out`, `retired`, `no_spawn`, `spawn_failed`, `unpaid_fines`, `insufficient_funds`, `world_limit`, `external_invoice`. Security rejections reach the client as `false, reason`; `client/main.lua` converts them to `{ok=false, error=reason}`. Prices and fees are never accepted from the NUI; the server computes them from config/DB.

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
| `mdp_garages:getVehicles` | lib.callback | C→S | NUI `getVehicles` | `{garage_id}` | RATE(5/10s), schema `garage_id=V.isGarageId`, GAR(`{public,private}`), DIST(garage 10 m); returns only vehicles the player owns or holds keys for, coords filtered by the visibility rule |
| `mdp_garages:takeOut` | lib.callback | C→S | NUI `takeOut` | `{plate, garage_id}` | schema (`plate`, `V.isGarageId`), RATE(1/s), GAR(`{public,private}`), DIST(garage), `requireOwnership` (owner or key holder), fines threshold if enabled; inside `WithLock(plate, src, fn)`: `GetSpawnedEntity(plate)` must be nil, ATOM(1→0), `CreateVehicleServerSetter` at a `GetGarage().spawns` point, `TrackSpawn` |
| `mdp_garages:storeVehicle` | lib.callback | C→S | player in a garage zone | `{netId, garage_id, props}` | RATE(1/s), GAR(`{public,private}`), DIST(garage 10 m + vehicle 5 m). The server resolves `NetworkGetEntityFromNetworkId(netId)`, checks the entity exists and is a vehicle, reads the plate **server-side** with `Utils.NormalizePlate(GetVehicleNumberPlateText(ent))` (no client plate is accepted; schema has no `plate` field), then calls `Security.IsOwner(src, plate)` manually. Inside `WithLock(plate, src, fn)`: ATOM(0→1), props size cap + model match against DB, `UntrackSpawn`, delete entity, slot limit for private garages |
| `mdp_garages:parkWorld` | lib.callback | C→S | player parks on the street | `{netId}` | RATE(1/s), DIST(vehicle 5 m), plate read server-side, OWN, world limits (refused with `world_limit` + notify), `WithLock(plate, src, fn)`, ATOM(0→2), sets `parked_at`, coords/heading read from the server entity |
| `mdp_garages:client:applyProps` | event | S→C | server after spawning a persistent car | `{netId, props}` | server-originated; client only applies props |
| `mdp_garages:syncWear` | lib.callback | C→S | client every N min while driving / on exit | `{netId, mileageDelta}` | RATE, src is the driver, plate read server-side, OWN/key, delta clamped by max plausible speed × time. **Health is read server-side** (`GetVehicleEngineHealth`/`GetVehicleBodyHealth` on the server entity), never from the client; fuel via `Bridge.Fuel` |
| `mdp_garages:giveKey` | lib.callback | C→S | owner shares a key | `{plate, target}` | schema, RATE, OWN! (`IsOwner(src, plate, false)`), target player within 5 m, max keys per vehicle; `Bridge.Keys` adapter |
| `mdp_garages:removeKey` | lib.callback | C→S | owner revokes a key | `{plate, holder}` | schema, RATE, OWN! |
| `mdp_garages:issueFine` | lib.callback | C→S | police / parking warden | `{netId, reason}` | JOB (`requireDuty` default true), DIST(vehicle), plate read from the entity server-side, amount from config (AMT), RATE; `Bridge.Billing.IssueFine` |
| `mdp_garages:payFine` | lib.callback | C→S | player / phone app | `{fineId}` | RATE, fine owner == identifier, AMT, `UPDATE … WHERE id=? AND paid=0` (ATOM) |
| `mdp_garages:towVehicle` | lib.callback | C→S | tow job | `{netId}` | RATE(1/s), JOB (on duty), DIST(vehicle), plate read server-side, `WithLock(plate, src, fn)`, ATOM(→3), insert into `mdp_impound` |
| `mdp_garages:impoundVehicle` | lib.callback | C→S | police | `{netId, reasonId, garage_id='impound:<id>'}` | RATE(1/s), JOB+minGrade (on duty), GAR(`impound`), DIST(vehicle), plate read server-side, **fee and release_after computed server-side from `Config.ImpoundReasons[reasonId]`** (client sends no amounts), `WithLock`, ATOM(→3) |
| `mdp_garages:releaseImpound` | lib.callback | C→S | owner at the impound lot | `{plate, garage_id='impound:<id>'}` | RATE, GAR(`impound` only), DIST(lot), OWN!, `release_after <= NOW()`, fee from `mdp_impound` via RemoveMoney (AMT), `WithLock(plate, src, fn)`, ATOM(3→1) |
| `mdp_garages:client:setGps` | event | S→C | server after an impound or on request | `{x,y,z}` | server-originated |
| `mdp_garages:buyPrivateGarage` | lib.callback | C→S | player at a property | `{config_id}` | schema, RATE(1/s), private-garage config lookup, DIST, price from config (AMT). `INSERT` first (UNIQUE(owner, config_id) rejects duplicates), then charge; if the charge fails, `DELETE` the row, all inside a per-owner lock |
| `mdp_garages:enterPrivateGarage` | lib.callback | C→S | player at an entrance | `{garage_id}` | RATE(1/s), GAR(`private`), owner or allowed player, DIST(entrance), routing bucket set server-side |
| `mdp_garages:phone:getVehicles` | lib.callback | C→S | phone app | `{}` | RATE(5/10s), OWN/key vehicles only, coords per visibility rule |
| `mdp_garages:client:notify` | event | S→C | last-resort Bridge.Notify fallback | `msg, type` | server-originated |

Rule: no client→server **event** may change state or money.

## Open questions
1. The example garage and impound coords are approximate and need checking in-game.
2. Private garage definitions: the property/interior config shape (`config_id`, price, slots) and the server-side `Utils.PrivateGarageLookup` arrive in the private-garages phase.
3. `takeOut` spawns with vehicle type `'automobile'`. Bikes, boats and aircraft need a per-model type (model metadata or a client-side lookup).
4. Disconnect policy: keep the car in the world (current behaviour), or add `Config.OnDisconnect = 'keep'|'garage'|'impound'`?
5. ESX `parking` column values are mapped to `public:<value>`, and unknown ones fall back to `Config.DefaultGarage`. Should there be an explicit mapping table in config?
