# mdp_garages — Integraciones

Leyenda: ✅ verificado contra el código/docs oficiales (16/10/2026) · ⚠️ NO verificado (basado en uso habitual; confirmar antes de publicar).

Convenciones comunes a todos los adaptadores:

```lua
-- bridge/init.lua ya define started(res). Reutilizar:
local function started(res) local s = GetResourceState(res) return s == 'started' or s == 'starting' end
-- Patrón: Config.X = 'auto' | '<recurso>' | 'none'. 'auto' recorre la lista en orden y se queda con el primero arrancado.
local function pick(cfg, order)
    if cfg and cfg ~= 'auto' then return cfg end
    for _, r in ipairs(order) do if started(r) then return r end end
    return 'none'
end
local function try(fn, ...) local ok, res = pcall(fn, ...) if not ok then print(('^3[mdp_garages] adapter error: %s^0'):format(res)) return nil end return res end
```

---

## 1. Adaptadores requeridos

### 1.1 Facturación (Billing) — `Config.Billing` + `Config.ChargeMode` (servidor)

`Config.ChargeMode = 'instant'` (por defecto): se cobra al momento con `Bridge.RemoveMoney`. Con `'invoice'` se emite una factura mediante el adaptador de billing. Si no hay adaptador, se vuelve a `'instant'`.

**Contrato (Backend, `bridge/billing/init.lua`; este archivo no se edita):**
- Cada adaptador se registra con `Bridge.RegisterAdapter('billing', '<recurso>', impl)` e implementa `SendBill(src, target, amount, reason, society, meta)`, que devuelve un boolean.
- `meta.fineId` es el `mdp_fines.id`. Se guarda con la factura en `mdp_fine_invoices(provider VARCHAR(32), invoice_id VARCHAR(64), fine_id INT UNSIGNED)` (PK `(provider, invoice_id)`, índice en `fine_id`) mediante `bridge/billing/_common.lua`. La tabla se crea en `sql/install.sql` (Backend), no en tiempo de ejecución.
- `impl.SupportsPaidHook = true` solo si el recurso emite un evento/export de pago verificado. Al pagar, el adaptador llama a `Bridge.Billing.MarkFinePaid(fineId, source)` sin importes (nunca se confía en el importe que llega del evento).
- `Bridge.Billing.IssueFine` escribe primero en `mdp_fines` y después llama a `SendBill`. Si no hay paid hook, se paga con `/mdp_payfine` o desde la UI (`server/fines.lua`).

| Recurso | Firma | Paid hook | Estado |
|---|---|---|---|
| esx_billing | `exports.esx_billing:BillPlayer(targetId, senderIdentifier, sharedAccountName, label, amount)` devuelve `insertedId|false`; `BillPlayerByIdentifier(targetIdentifier, senderIdentifier, sharedAccountName, label, amount)`; evento de red `esx_billing:sendBill(targetId, sharedAccountName, label, amount)`; evento local `esx_billing:sendBillToIdentifier` | `TriggerEvent('esx_billing:paidBill', source, billId)` → **true** | ✅ https://github.com/esx-framework/ESX-Legacy-Addons/blob/main/%5Besx_addons%5D/esx_billing/server/main.lua |
| qb-phone | Sin export de factura: el `/bill` oficial hace `INSERT INTO phone_invoices (citizenid, amount, society, sender, sendercitizenid)` y luego `TriggerClientEvent('qb-phone:RefreshPhone', target)` | `TriggerEvent('qb-phone:server:paidInvoice', source, invoiceId)` (también existe `declinedInvoice`) → **true** | ✅ https://github.com/qbcore-framework/qb-phone/blob/main/server.lua |
| Qbox | No hay recurso de billing oficial. `Qbox-project/qbx_phone` está archivado. Qbox usa qb-phone, lb-phone, npwd o okok. `Config.Billing = 'qbx_core'` (prioridad de `init.lua`) no tiene API de facturas: solo sirve para el modo instant. | — | ✅ (lista de repos de la organización Qbox-project) |
| okokBilling | `TriggerServerEvent("okokBilling:CreateCustomInvoice", target, price, reason, invoiceSource, society, societyName, authorIdentifier)` (documentado para el cliente) | No documentado → **false** (`SupportsFines = false`: no se usa para multas); además no devuelve un id de factura | ✅ firma: https://docs.okokscripts.io/scripts/okokbilling/snippets · ⚠️ llamarlo desde el servidor con `TriggerEvent` (recurso escrow, no se puede ver el código) |

**Multas: canales y revisión (decisiones del Senior):**
- `impl.SupportsFines`: vale `true` en esx_billing y qb-phone, y `false` en **okokBilling**. okok **no se usa para multas** porque no tiene paid hook ni devuelve un id de factura. Si okok está detectado, `IssueFine` envía la multa por el canal `internal` (`/mdp_payfine` o la UI) y al arrancar se muestra un aviso en consola. okok sigue siendo válido para tasas con `Config.ChargeMode = 'invoice'`.
- `mdp_fines.channel` (`Constants.FineChannel`) puede ser `internal`, `invoice`, `external` o `needs_review`. `mdp_fines.paid` (`Constants.FineStatus`) puede ser `UNPAID=0`, `PAID=1`, `CHARGING=2` (alias obsoleto `CLAIMING`) o `VOIDED=3`. La anulación usa `paid = VOIDED`, sin columna nueva, y está aislada en `voidFine()` dentro de `server/fine_review.lua`.
- `Bridge.BillingCommon.Link(...)` devuelve un boolean y registra el fallo en el log. Si `SendBill` crea la factura pero el enlace no se guarda (`HasInvoice` es false), `IssueFine` pone `channel = 'needs_review'` y lo registra en el log. Con ese estado, `/mdp_payfine` queda bloqueado para evitar el doble cobro.
- `Bridge.BillingCommon.OnPaid` es idempotente: resuelve el `fineId` solo a través de `mdp_fine_invoices`, usa un guard in-flight por `fineId` y llama a `MarkFinePaid` como máximo una vez. Nunca mueve dinero.
- Comando de administración `/mdp_finereview <id> paid|void` (`server/fine_review.lua`). Lo puede usar la consola o cualquiera con el ACE `mdp_garages.admin` (`add_ace group.admin mdp_garages.admin allow`). Solo actúa sobre filas con `channel='needs_review'` y `paid=UNPAID`:
  - `paid` → `Bridge.Billing.MarkFinePaid(id, src)` y después `channel = 'invoice'` (el pago se hizo por la factura externa).
  - `void` → `UPDATE mdp_fines SET paid = VOIDED WHERE id = ? AND paid = UNPAID AND channel = 'needs_review'`. Solo cuenta como éxito si `affectedRows == 1`.
  - Cada acción se registra en el log de consola y se notifica con `Bridge.Notify`.

**Correcciones tras QA (`docs/qa-review-adapters-phase0.md`):**
- Los helpers ya no son globales: ahora son `Bridge.FuelCommon`, `Bridge.KeysCommon` y `Bridge.BillingCommon`.
- esx_billing y qb-phone: una vez creada la factura, `SendBill` devuelve siempre `true`. Si el enlace falla (`Bridge.BillingCommon.SafeLink` devuelve false), se registra en el log e `IssueFine` pasa la multa a `needs_review` (nunca a `internal`).
- `OnPaid`: si `MarkFinePaid` falla, se registra siempre en el log y la multa (`UNPAID` + `invoice`) pasa a `needs_review`.
- okokBilling: ⚠️ el uso de `CreateCustomInvoice` desde el servidor **no está verificado** (el handler probablemente depende de `source`). Va **el último** en la prioridad automática. Nunca se usa para multas. Para tasas solo se dispara si `Config.OkokTrustServerEvent = true`; si no, `SendBill` devuelve `false` y se cobra en modo instant.
- Keys: las matrículas se normalizan con `Utils.NormalizePlate` / `Utils.IsValidPlate`. En el cliente, qbx `HasKeys` acepta una entidad o una matrícula (busca la entidad en el pool `CVehicle`).
- qbx_vehiclekeys en el cliente: `HasKeys(vehicle)` recibe una **entidad** (✅ `client/functions.lua`: `---@param vehicle number`, usa `Entity(vehicle).state`). El adaptador convierte la matrícula en entidad con `Bridge.KeysCommon.ToEntity`. `ToPlate` normaliza con `Utils.NormalizePlate` dentro del propio helper.
- `/mdp_finereview` usa las claves de locale `finereview_usage`, `finereview_paid`, `finereview_voided` y `finereview_nochange` (en `locales/es.lua` y `locales/en.lua`).
- ox_lib: `info` se traduce a `inform` (`TYPES` en `bridge/notify/ox_lib.lua`; ox_lib solo acepta `inform|success|error|warning`).

Implementado en `bridge/billing/esx_billing.lua`, `qb-phone.lua`, `okokBilling.lua` y `_common.lua`. Ejemplo (esx_billing):
```lua
Bridge.RegisterAdapter('billing', 'esx_billing', {
    SupportsPaidHook = true,
    SendBill = function(src, target, amount, reason, society, meta)
        if not Bridge.ValidAmount(amount) then return false end
        local id = exports.esx_billing:BillPlayer(target, Bridge.GetIdentifier(src) or 'server', 'society_' .. (society or 'police'), reason, amount)
        if not id then return false end
        Bridge.BillingCommon.Link('esx_billing', id, meta); return true
    end,
})
AddEventHandler('esx_billing:paidBill', function(src, billId)
    if GetInvokingResource() ~= 'esx_billing' then return end
    Bridge.BillingCommon.OnPaid('esx_billing', billId, src) -- -> Bridge.Billing.MarkFinePaid(fineId, src)
end)
```
Uso desde el core: `if Config.ChargeMode == 'invoice' and Bridge.Billing.Get() then Bridge.Billing.IssueFine(...) else Bridge.RemoveMoney(src, 'bank', fee, reason) end`.

### 1.2 Combustible (Fuel) — `Config.Fuel = 'auto'` (cliente; ox_fuel también servidor)

Orden auto: `ox_fuel` → `cdn-fuel` → `LegacyFuel` → `ps-fuel`/`lc_fuel` (⚠️) → nativo.

| Recurso | Lado | Firma | Estado |
|---|---|---|---|
| LegacyFuel | cliente | `exports['LegacyFuel']:GetFuel(vehicle)` → number; `exports['LegacyFuel']:SetFuel(vehicle, fuel)` | ✅ funciones `GetFuel/SetFuel` en `source/fuel_client.lua`, exportadas en fxmanifest — https://github.com/InZidiuZ/LegacyFuel |
| ox_fuel | cliente/servidor | Sin exports get/set: leer `Entity(veh).state.fuel` (o `GetVehicleFuelLevel`), escribir `Entity(veh).state.fuel = n`. En servidor: `Entity(NetworkGetEntityFromNetworkId(netId)).state.fuel = n` | ✅ README oficial — https://github.com/overextended/ox_fuel |
| cdn-fuel | cliente | `exports['cdn-fuel']:GetFuel(vehicle)`, `exports['cdn-fuel']:SetFuel(vehicle, fuel)` | ✅ fxmanifest + `client/utils.lua` — https://github.com/CodineDev/cdn-fuel |

```lua
-- bridge/fuel/client.lua
local F = pick(Config.Fuel, { 'ox_fuel', 'cdn-fuel', 'LegacyFuel' })
function Bridge.GetFuel(veh)
    if not DoesEntityExist(veh) then return 0.0 end
    if F == 'ox_fuel' then return Entity(veh).state.fuel or GetVehicleFuelLevel(veh) end
    if F == 'cdn-fuel' or F == 'LegacyFuel' then
        local v = try(function() return exports[F]:GetFuel(veh) end)
        if v then return v end
    end
    return GetVehicleFuelLevel(veh)
end
function Bridge.SetFuel(veh, fuel)
    fuel = math.max(0.0, math.min(100.0, (tonumber(fuel) or 100.0) + 0.0))
    if F == 'ox_fuel' then Entity(veh).state:set('fuel', fuel, true) end -- requiere ownership de red
    if F == 'cdn-fuel' or F == 'LegacyFuel' then
        if try(function() exports[F]:SetFuel(veh, fuel) return true end) then return end
    end
    SetVehicleFuelLevel(veh, fuel)
end
```
Nota: con ox_fuel, si el vehículo se crea en servidor (`CreateVehicleServerSetter`), fijar `Entity(veh).state.fuel` en servidor justo tras crearlo.

### 1.3 Llaves externas — `Config.Keys = 'auto'`

Orden auto: `qbx_vehiclekeys` → `qb-vehiclekeys` → `internal` (sistema propio de mdp_garages, ver §2).

| Recurso | Lado | Firma | Estado |
|---|---|---|---|
| qbx_vehiclekeys | servidor | `exports.qbx_vehiclekeys:GiveKeys(source, vehicle, skipNotification)`, `:RemoveKeys(source, vehicle, skipNotification)`, `:HasKeys(source, vehicle)` (vehicle = entidad) ; `:SetLockState(vehicle, state)` | ✅ `server/keys.lua` — https://github.com/Qbox-project/qbx_vehiclekeys |
| qbx_vehiclekeys | cliente | `exports.qbx_vehiclekeys:HasKeys(vehicle)` → boolean | ✅ `client/functions.lua` |
| qb-vehiclekeys | cliente | `exports['qb-vehiclekeys']:HasKeys(plate)`; eventos `vehiclekeys:client:SetOwner(plate)`, `qb-vehiclekeys:client:AddKeys(plate)`, `qb-vehiclekeys:client:RemoveKeys(plate)` | ✅ https://github.com/qbcore-framework/qb-vehiclekeys/blob/main/client.lua |
| qb-vehiclekeys | servidor | `exports['qb-vehiclekeys']:GiveKeys(id, plate)`, `:RemoveKeys(id, plate)`, `:HasKeys(id, plate)` → boolean (por matrícula, no por entidad) | ✅ https://github.com/qbcore-framework/qb-vehiclekeys/blob/main/server.lua |

```lua
-- bridge/keys/server.lua
local K = pick(Config.Keys, { 'qbx_vehiclekeys', 'qb-vehiclekeys' })
function Bridge.GiveKeys(src, veh, plate)
    if K == 'qbx_vehiclekeys' then
        if try(function() exports.qbx_vehiclekeys:GiveKeys(src, veh, true) return true end) then return true end
    elseif K == 'qb-vehiclekeys' then
        if try(function() exports['qb-vehiclekeys']:GiveKeys(src, plate) return true end) then return true end
        TriggerClientEvent('vehiclekeys:client:SetOwner', src, plate) return true
    end
    return Keys.Internal.Give(src, plate) -- tabla propia
end
function Bridge.RemoveKeys(src, veh, plate)
    if K == 'qbx_vehiclekeys' then return try(function() exports.qbx_vehiclekeys:RemoveKeys(src, veh, true) return true end) or false
    elseif K == 'qb-vehiclekeys' then return try(function() exports['qb-vehiclekeys']:RemoveKeys(src, plate) return true end) or false end
    return Keys.Internal.Remove(src, plate)
end
function Bridge.HasKeys(src, veh, plate)
    if K == 'qbx_vehiclekeys' then return try(function() return exports.qbx_vehiclekeys:HasKeys(src, veh) end) == true end
    if K == 'qb-vehiclekeys' then return try(function() return exports['qb-vehiclekeys']:HasKeys(src, plate) end) == true end
    return Keys.Internal.Has(src, plate)
end
```

### 1.4 Notificaciones — `Config.Notify = 'auto'`

ox_lib es **obligatorio** (`dependencies { 'oxmysql', 'ox_lib' }` y `'@ox_lib/init.lua'` en shared_scripts). Por defecto se usa `lib.notify`. `Config.Notify = 'framework'` fuerza el notify nativo del framework. El feed nativo de GTA solo se usa como fallback si `lib.notify` falla.

| Origen | Lado | Firma | Estado |
|---|---|---|---|
| ox_lib | cliente | `lib.notify({ title, description, type = 'inform'|'success'|'error'|'warning', duration })` (requiere `@ox_lib/init.lua`) | ✅ https://overextended.dev/ox_lib/Modules/Interface/Client/notify |
| ox_lib | servidor | `TriggerClientEvent('ox_lib:notify', src, data)` (mismo formato; usado así en el README de ox_fuel) | ✅ |
| ESX | cliente / servidor | `ESX.ShowNotification(msg, type, length)` / `TriggerClientEvent('esx:showNotification', src, msg, type, length)` | ✅ (ya usado en `bridge/esx.lua`) |
| QBCore | cliente / servidor | `QBCore.Functions.Notify(text, type, length)` / `TriggerClientEvent('QBCore:Notify', src, text, type, length)` | ✅ (ya en `bridge/qb.lua`) |
| Qbox | cliente / servidor | `exports.qbx_core:Notify(text, type, duration)` / `exports.qbx_core:Notify(src, text, type, duration)` | ✅ (ya en `bridge/qbx.lua`) |

Mapeo de tipos: mdp usa `'success'|'error'|'info'|'warning'`; para ox_lib traducir `info → inform`; para QB `info → primary`.

```lua
-- cliente
function Bridge.Notify(msg, ntype)
    if Config.Notify ~= 'framework' and pcall(lib.notify, { title = 'Garaje', description = msg, type = ntype == 'info' and 'inform' or ntype or 'inform' }) then return end
    FrameworkNotify(msg, ntype) -- esx/qb/qbx; si es standalone, feed nativo
end
-- servidor
function Bridge.Notify(src, msg, ntype)
    TriggerClientEvent('ox_lib:notify', src, { title = 'Garaje', description = msg, type = ntype == 'info' and 'inform' or ntype or 'inform' })
end
```
Tabla `mdp_fine_invoices`: definida en `sql/install.sql` (`fine_id INT UNSIGNED`, igual que `mdp_fines.id`).
En servidor: `Bridge.Notify(src, ...)` → si ox_lib, `TriggerClientEvent('ox_lib:notify', src, {...})`.

### 1.5 Teléfonos — `Config.Phone = 'auto'`

Orden auto: `lb-phone` → `npwd` → `qb-phone` → `none`. En las fases 1–6 solo hay correo y notificaciones (incautación, recibo, vehículo listo). **La app de garaje se aplaza a la fase 7 y se hará primero para lb-phone** (`AddCustomApp`, más adelante npwd y qb-phone).

| Recurso | Lado | Firma | Estado |
|---|---|---|---|
| lb-phone | servidor | `exports["lb-phone"]:GetEquippedPhoneNumber(source|identifier)` → string?; `exports["lb-phone"]:GetEmailAddress(phoneNumber)` → string?; `exports["lb-phone"]:SendMail({ to, sender?, subject?, message?, attachments?, actions? })` → `success, id|reason`; `exports["lb-phone"]:SendNotification(target, { app, title?, content?, ... })`, donde target es un número de teléfono (se guarda) o un source (no se guarda) | ✅ https://docs.lbscripts.com/phone/exports/server-exports/ (extraído del contenido SSR de la página) |
| npwd | servidor | `exports.npwd:getPlayerData({ source | identifier | phoneNumber })`; `generatePhoneNumber()` | ✅ https://github.com/project-error/npwd/blob/master/apps/game/server/bridge/sv_exports.ts |
| npwd | **cliente** | `exports.npwd:createNotification({ notisId, appId, content, secondaryTitle, keepOpen, duration, path })` (`notisId` es obligatorio); `createSystemNotification({ uniqId, ... })` | ✅ https://github.com/project-error/npwd/blob/master/apps/game/client/cl_exports.ts. Desde el servidor hay que enviar un evento propio al cliente. `emitMessage` ⚠️: no aparece entre los exports actuales (solo `emitRconMessage`) |
| qb-phone | servidor | `exports['qb-phone']:sendNewMailToOffline(citizenid, { sender, subject, message, button? })` (sirve también para jugadores online) | ✅ https://github.com/qbcore-framework/qb-phone/blob/main/server.lua |
| qb-phone | cliente | `TriggerEvent('qb-phone:client:CustomNotification', title, text, icon, color, timeout)`; evento de red `qb-phone:server:sendNewMail(mailData)` | ✅ client.lua / server.lua. `exports['qb-phone']:PhoneNotification` ⚠️: lo usa cdn-fuel, pero el qb-phone actual **no** lo exporta; no usarlo |

```lua
-- bridge/phone/server.lua
local P = pick(Config.Phone, { 'lb-phone', 'npwd', 'qb-phone' })
function Bridge.PhoneMail(src, subject, message)
    if P == 'lb-phone' then
        local ok = try(function()
            local num = exports['lb-phone']:GetEquippedPhoneNumber(src); if not num then return false end
            local mail = exports['lb-phone']:GetEmailAddress(num)
            if mail then exports['lb-phone']:SendMail({ to = mail, sender = 'Garaje', subject = subject, message = message })
            else exports['lb-phone']:SendNotification(num, { app = 'Mail', title = subject, content = message }) end
            return true
        end)
        if ok then return true end
    elseif P == 'npwd' then
        TriggerClientEvent('mdp_garages:client:npwdNotify', src, subject, message) -- el cliente llama a exports.npwd:createNotification
        return true
    elseif P == 'qb-phone' then
        local cid = Bridge.GetIdentifier(src)
        if cid then exports['qb-phone']:sendNewMailToOffline(cid, { sender = 'Garaje', subject = subject, message = message }) return true end
    end
    Bridge.Notify(src, subject .. ': ' .. message, 'info') -- fallback
    return false
end
```

### 1.6 Claves de configuración propuestas (`shared/config.lua`)

```lua
Config.Framework = 'auto' -- ya existe
Config.Billing   = 'auto' -- 'okokBilling' | 'esx_billing' | 'qb-phone' (prioridad en bridge/billing/init.lua)
Config.ChargeMode = 'instant' -- 'instant' | 'invoice'  (añadido a shared/config.lua)
Config.Fuel      = 'auto' -- 'ox_fuel' | 'cdn-fuel' | 'LegacyFuel' | 'native'
Config.Keys      = 'auto' -- 'qbx_vehiclekeys' | 'qb-vehiclekeys' | 'internal'
Config.Notify    = 'auto' -- 'auto'/'ox_lib' (lib.notify) | 'framework'
Config.Phone     = 'auto' -- 'lb-phone' | 'npwd' | 'qb-phone' | 'none'
```

---

## 2. API pública de exports de mdp_garages

Estados de vehículo: `mdp_vehicles.state` es TINYINT. Las constantes están en `shared/constants.lua` (ya existía, no se ha modificado):
```lua
Constants.VehicleState = { OUT = 0, GARAGED = 1, PARKED_WORLD = 2, IMPOUNDED = 3, RETIRED = 4 }
Constants.FineStatus   = { UNPAID = 0, PAID = 1, CHARGING = 2 --[[alias CLAIMING]], VOIDED = 3 }
```
Nota: la decisión decía `PARKED`, pero el archivo existente usa `PARKED_WORLD`. Se mantiene `PARKED_WORLD`. Todas las tablas llevan el prefijo `mdp_` (`mdp_vehicles`, `mdp_fines`, `mdp_fine_invoices`). `vehicle` es la matrícula (string), salvo que se indique otra cosa.

| Export | Lado | Parámetros | Retorno |
|---|---|---|---|
| `HasKeys(src, plate)` | servidor | src:number, plate:string | boolean |
| `HasKeys(plate)` | cliente | plate:string\|entity | boolean |
| `GiveKeys(src, plate, opts?)` | servidor | opts `{ temporary?:bool, silent?:bool }` | boolean |
| `RemoveKeys(src, plate, opts?)` | servidor | ídem | boolean |
| `GetVehicleState(plate)` | servidor | plate | `{ state:integer(VehicleState), garage, fuel, engine, body, owner }` \| nil |
| `SetVehicleState(plate, state, garage?)` | servidor | state: integer de `Constants.VehicleState` (0–4), garage:string opcional | boolean |
| `ImpoundVehicle(plate, data?)` | servidor | data `{ fee?:number, reason?:string, by?:number(src), lot?:string, until?:unix }` | boolean, err? |
| `ReleaseImpound(plate, src?, chargeFee?)` | servidor | src que paga; chargeFee default true | boolean, err? |
| `GetPlayerVehicles(src\|identifier, filter?)` | servidor | filter `{ state?, garage?, type? }` | array de `{ plate, model, state:integer, garage, fuel }` |

Todos los exports validan entradas (`type(plate)=='string'`, normalizan con `plate:upper():gsub('^%s*(.-)%s*$','%1')`) y nunca lanzan error: devuelven `false, 'motivo'`. **Seguridad:** solo exports de servidor modifican estado; ningún evento de red cliente→servidor permite `SetVehicleState`/`ImpoundVehicle` sin comprobar job (`Config.ImpoundJobs`) en servidor.

Ejemplos:
```lua
-- otro recurso (servidor)
if exports.mdp_garages:HasKeys(source, 'ABC 123') then ... end
exports.mdp_garages:GiveKeys(source, plate, { temporary = true })
local ok, err = exports.mdp_garages:ImpoundVehicle(plate, { fee = 500, reason = 'Mal aparcado', by = source })
local st = exports.mdp_garages:GetVehicleState(plate) -- st.state == Constants.VehicleState.IMPOUNDED (3)
exports.mdp_garages:SetVehicleState(plate, Constants.VehicleState.GARAGED, 'legion')
for _, v in ipairs(exports.mdp_garages:GetPlayerVehicles(source, { state = Constants.VehicleState.GARAGED })) do print(v.plate) end
-- cliente
if exports.mdp_garages:HasKeys(GetVehiclePedIsIn(PlayerPedId(), false)) then ... end
```

Implementación (server/exports.lua):
```lua
exports('GetVehicleState', function(plate)
    local ok, row = pcall(MySQL.single.await, 'SELECT state, garage, fuel, engine, body, owner FROM mdp_vehicles WHERE plate = ?', { plate })
    return ok and row or nil
end)
```

### Eventos

| Evento | Lado (emisión) | Payload |
|---|---|---|
| `mdp_garages:vehicleStored` | servidor (TriggerEvent local) | `src, plate, garage` |
| `mdp_garages:vehicleSpawned` | servidor | `src, plate, netId, garage` |
| `mdp_garages:vehicleImpounded` | servidor | `plate, data` |
| `mdp_garages:impoundReleased` | servidor | `plate, src, fee` |
| `mdp_garages:keysChanged` | servidor | `src, plate, hasKeys:boolean` |
| `mdp_garages:client:vehicleSpawned` | cliente (TriggerClientEvent al dueño) | `netId, plate` |
| `mdp_garages:client:notify` | cliente | `msg, type` (ya existe) |

Los eventos de servidor se emiten con `TriggerEvent` (no son net events), así ningún cliente puede falsificarlos. Ejemplo: `AddEventHandler('mdp_garages:vehicleImpounded', function(plate, data) ... end)`.

---

## 3. Estructura de `bridge/` (estado actual)

Backend ya movió los archivos de framework y actualizó `fxmanifest.lua`. Integrations no ha movido ningún archivo. Estructura actual:
```
bridge/
  init.lua                    -- framework detection, Bridge.RegisterAdapter / ResolveAdapter / SafeCall (Backend)
  framework/{qbx,qb,esx}.lua  -- Backend
  notify/init.lua  fuel/init.lua  keys/init.lua  phone/init.lua  -- loaders/interfaces (Backend)
  billing/init.lua            -- contract + MarkFinePaid/IssueFine (Backend)
  billing/_common.lua  billing/esx_billing.lua  billing/qb-phone.lua  billing/okokBilling.lua  -- Integrations
```
Los siguientes adaptadores (fuel, keys, phone) van como `bridge/<tipo>/<recurso>.lua` y se registran con `Bridge.RegisterAdapter`. Como `fxmanifest` usa globs `bridge/<tipo>/*.lua`, no hace falta tocarlo.

Orden de auto-detección (`PRIORITY` en cada `init.lua`):
1. Framework: `qbx_core` → `qb-core` → `es_extended` → standalone.
2. Notify: ox_lib (obligatorio) → framework.
3. Fuel: `ox_fuel` → `cdn-fuel` → `LegacyFuel` → nativo.
4. Keys: `qbx_vehiclekeys` → `qb-vehiclekeys` → interno.
5. Billing (propuesta tras QA): `esx_billing` → `qb-phone` → `okokBilling` (el último). Después, cualquier adaptador registrado que esté arrancado (p. ej. `qb-phone`) → instant.
6. Phone: `lb-phone` → `npwd` → `qb-phone` → none.

## Fuentes
✅ ox_fuel README · LegacyFuel · cdn-fuel (fxmanifest, client/utils.lua) · qbx_vehiclekeys (server/keys.lua, client/functions.lua) · ox_lib notify · esx_billing: https://github.com/esx-framework/ESX-Legacy-Addons · qb-vehiclekeys client.lua/server.lua · qb-phone client.lua/server.lua · npwd cl_exports.ts / sv_exports.ts · lb-phone https://docs.lbscripts.com/phone/exports/server-exports/ · okokBilling snippets https://docs.okokscripts.io/scripts/okokbilling/snippets.md

⚠️ Pendiente: okokBilling desde el servidor y su evento de pago (recurso escrow); npwd `emitMessage`; qb-phone `PhoneNotification` (no existe en el qb-phone actual).

---

## Fase 1 — API nueva (Integrations)

### Combustible
| Función | Lado | Retorno |
|---|---|---|
| `Bridge.Fuel.Call('GetFuel', fallback, veh)` / `Bridge.Fuel.Call('SetFuel', fallback, veh, value)` | cliente (ox_fuel también servidor) | number / boolean; si no hay adaptador, se usan los nativos (`Bridge.FuelCommon`) |
| `Bridge.FuelCommon.ServerCapable()` | servidor | `true` solo con **ox_fuel** (statebag); propuesta de alias `Bridge.Fuel.ServerCapable` en `fuel/init.lua` |
| `Bridge.FuelCommon.Clamp(v)` | ambos | número limitado a 0–100 (con NaN, 100) |

**Requisito en el cliente:** con LegacyFuel, cdn-fuel o nativo, `SetFuel` tiene que ejecutarse **en el cliente dueño de la entidad** después del spawn (`Bridge.Props.Apply` lo hace con `props.fuelLevel`). Al guardar, el servidor lee el valor que manda el cliente, limitado a 0–100 (`Bridge.Props.Sanitize`). Con ox_fuel, el servidor puede fijar `Entity(veh).state.fuel` él mismo.

### Llaves (`bridge/keys/zz_api.lua`)
| Función | Lado | Retorno |
|---|---|---|
| `Bridge.Keys.GiveKeys(src, vehicle entity|plate)` | servidor | boolean (`true` también cuando no hay recurso externo: `mdp_vehicle_keys` hace de almacén de respaldo) |
| `Bridge.Keys.RemoveKeys(src, vehicle entity|plate)` | servidor | boolean |
| `Bridge.Keys.HasKeys(src, vehicle)` | servidor | boolean, o `nil` si no hay recurso externo (en ese caso se consulta `mdp_vehicle_keys`) |
| `Bridge.Keys.HasKeys(vehicle)` | cliente | boolean o `nil` |

Adaptadores: `qbx_vehiclekeys` (entidad), `qb-vehiclekeys` (matrícula), y además:
| Recurso | Exports usados (servidor) | Estado |
|---|---|---|
| wasabi_carlock | `GiveKey(src, plate)` (devuelve la matrícula), `RemoveKey(src, plate)` → bool, `HasKey(src, plate)` → bool | ✅ docs https://docs.wasabiscripts.com/advanced-series/wasabi-carlock/exports (recurso escrow) |
| MrNewbVehicleKeys | `GiveKeysByPlate(src, plate, autoKeyring)`, `RemoveKeysByPlate(src, plate, deepSearch)` | ✅ docs https://mrnewbs-scrips.gitbook.io/guide/mrnewbvehiclekeys-beta/vehicle-keys-exports/server-exports · ⚠️ no se ha confirmado un `HasKeys` en servidor, así que no se usa |
| qs-vehiclekeys | `GiveServerKeys(src, plate, model, false)`, `RemoveServerKeys(src, plate, model)`; `model` se toma de `mdp_vehicles.model` | ✅ docs https://www.quasar-store.com/docs/vehiclekeys/commands-and-exports (escrow) |
| jaksam vehicles_keys | solo hay un evento de cliente público (`vehicles_keys:selfGiveVehicleKeys`) | ⚠️ sin API de servidor verificada; no implementado |

### Propiedades del vehículo (`bridge/vehicle/props.lua`)
| Función | Lado | Retorno |
|---|---|---|
| `Bridge.Props.Get(veh)` | cliente | tabla (`lib.getVehicleProperties` + `fuelLevel` del bridge de combustible) o `nil` |
| `Bridge.Props.Apply(veh, props|json)` | cliente | boolean (`lib.setVehicleProperties` + `SetFuel`) |
| `Bridge.Props.Sanitize(raw, expectedPlate?, dbRow?, entity?)` | ambos (usar en servidor). En servidor **delega en `Security.SanitizeProps`** si existe (es el único validador; lee `dbRow` de `mdp_vehicles` si no se pasa); si no existe, usa el validador local | `tabla, json` o `nil, err` (`too_large` si supera 64 KB, `invalid_json`, `invalid_props`, `encode_failed`). Solo conserva datos planos, con profundidad ≤ 6 y strings ≤ 256; limita fuel/engine/body/tank/dirt; fuerza la matrícula del servidor |
| `Bridge.Props.RequestApply(veh, payload, src?)` | servidor | boolean. Ver «Aplicación de props dirigida por el servidor» |

### Espejo en las tablas del framework (`bridge/vehicle/framework_sync.lua`)
Solo está activo si `Config.SyncFrameworkTables = true` y `Config.MirrorFrameworkTables ~= false`. Solo hace `UPDATE` sobre filas que ya existen, buscando por matrícula; nunca inserta ni borra. Las consultas son parametrizadas y van con pcall y log.
| Función | Lado | Retorno |
|---|---|---|
| `Bridge.FrameworkSync.Mirror(plate, { state?, garage_id?, props?, fuel?, engine?, body? })` | servidor | `true` si se actualizó una fila |
| `Bridge.FrameworkSync.OnStore(plate, garageId, props, fuel, engine, body)` / `OnSpawn(plate)` / `OnImpound(plate, impoundId)` / `OnRelease(plate)` | servidor | ídem. En ESX: `pound = impoundId` al incautar y `NULL` al liberar, solo si la columna existe (se detecta una vez con `INFORMATION_SCHEMA` y se cachea) |

Mapeo de estados: qb/qbx `player_vehicles.state`: OUT/PARKED_WORLD → 0, GARAGED → 1, IMPOUNDED → 2 (RETIRED/REMOVED no se tocan); también actualiza `mods`, `fuel` (entero), `engine`, `body` y `garage` cuando el vehículo se guarda. ESX `owned_vehicles`: `vehicle` = JSON de props, `stored` = 1 solo en GARAGED, y `parking` = garage_id al guardar.

### Llaves al guardar
`Config.RemoveKeysOnStore = true` (valor por defecto). La regla se aplica con `Bridge.Keys.OnStore(src, plate, newState)` (servidor):
- si `newState == GARAGED (1)`, llama a `Bridge.Keys.RemoveKeys(src, plate)` (las llaves **temporales** del recurso externo);
- si `PARKED_WORLD (2)`, se conservan;
- nunca toca `mdp_vehicle_keys` (las llaves compartidas de la fase 3);
- devuelve `true` si se quitaron las llaves;
- **solo quita las llaves del jugador que guarda el vehículo**, no las de otros ocupantes ni las de otros titulares temporales (confirmado por el Senior).

### Aplicación de props dirigida por el servidor
| Elemento | Nombre | Dirección |
|---|---|---|
| Statebag de entidad | `mdp:props` (JSON o la tabla de Backend `{props, engine, body, fuel, fuelOnClient, mileage}`) | servidor → todos |
| Ack | `mdp_garages:server:propsApplied(netId, ok, reason?)`: `ok = true` aplicado; `ok = false` + `reason` ∈ {`model_mismatch`, `invalid_props`} = fallo determinista | dueño → servidor (net) |
| Fallo final | `mdp_garages:client:propsApplyFailed` (netId) | servidor → jugador que hizo el spawn + dueño actual (net) |
| Resultado local | `mdp_garages:client:propsApplied` (netId, ok) | `TriggerEvent` local en el cliente dueño. **No está en red**, no se registra como net event |

Flujo:
1. El servidor llama a `Bridge.Props.RequestApply(veh, payload, src?)`, que fija el statebag y arranca un temporizador de 5 s.
2. El cliente que es (o pasa a ser en menos de 5 s) `NetworkGetEntityOwner` pide el control, aplica las props (`lib.setVehicleProperties`, salud del motor y la carrocería, `SetFuel` si `fuelOnClient`), envía el ack y emite el evento local con `ok`.
3. El servidor comprueba el ack: rate limit 10 cada 5 s, netId entero y que el remitente sea el dueño actual (si no, `Security.LogReject`). Después limpia el statebag y cancela el temporizador.
   - **Fallo determinista:** antes de aplicar, el cliente comprueba que el payload se puede decodificar y que `props.model` coincide con `GetEntityModel` en 32 bits. Si no, envía de inmediato `ok = false, reason`, **sin reintento**. El servidor aplica las mismas comprobaciones; si `reason` no está en la whitelist, lo rechaza con `LogReject`. Si es válido, limpia el statebag, cancela el temporizador, lo registra en el log y envía `propsApplyFailed` al jugador del spawn y al dueño.
   - El evento local `propsApplied(netId, false)` se emite **una sola vez**, al recibir `propsApplyFailed`. `propsApplied(netId, true)` se emite al aplicar con éxito.
4. **Solo si no hay respuesta** (o hay un error transitorio de `lib.setVehicleProperties`, que no envía ack): a los 5 s el servidor reintenta una vez (pone el statebag a nil y lo vuelve a fijar, así que un dueño nuevo también ve el cambio).
5. Si tampoco hay ack tras el reintento, registra el fallo en el log, limpia el statebag y envía `propsApplyFailed` al jugador del spawn y al dueño, que reemiten el evento local con `ok = false`.

Este es el **único applier**: el de `client/props.lua` (Backend) se elimina. El odómetro ya no puede leer `mileage` del statebag, porque se limpia tras el ack; tiene que usar un statebag propio (p. ej. `mdp:mileage`).

### Pendiente
- **jaksam vehicles_keys:** no hay API de servidor verificada (solo el evento de cliente `vehicles_keys:selfGiveVehicleKeys`). Se implementará cuando haya docs o código de exports de servidor.

---

## Concesionarios

mdp_garages solo deja guardar o aparcar vehículos **marcados por el servidor** (`Security.MarkServerEntity`). Un coche que el concesionario crea por su cuenta no se puede guardar, salvo por las vías 2 y 3. **Orden de preferencia: `SpawnOwnedVehicle` > `RegisterExternalVehicle` > adopción en el primer guardado.**

### Exports (servidor, solo se pueden llamar desde otro recurso)
**`AddVehicle`**: `exports.mdp_garages:AddVehicle(owner, plate, model, props?, garageId?) -> ok, err?` (`server/vehicles.lua:245-308`)
- `owner` = identificador del framework (citizenid en qb/qbx, `xPlayer.getIdentifier()` en ESX).
- `garageId = 'out'` crea la fila en OUT (necesario para las vías 1, 2 y 3); otro valor la crea en GARAGED en ese garaje; `nil`, en el garaje por defecto.
- La fila se crea con `managed_at` NULL, así que es adoptable. Las filas que llegan por import desde las tablas del framework se crean con `managed_at` ya fijado y **nunca son adoptables**.
- Errores: `invalid_owner`, `invalid_plate`, `invalid_model`, `invalid_props`, `plate_exists`, `db_error`.

**`SpawnOwnedVehicle`** (commit 53c2c56): `exports.mdp_garages:SpawnOwnedVehicle(plate, coords, src) -> netId | nil, err`
- `coords`: `vector3`/`vector4` o `{x, y, z, w?}`.
- Mismo flujo que sacar del garaje: lock; `owner` = identificador de `src`; estado GARAGED, u OUT sin entidad; marca, `TrackSpawn`, `RequestApply` de las props, combustible, llaves, `FrameworkSync`; rollback si falla.

| Error | Significado |
|---|---|
| `invalid_plate` | matrícula vacía o no válida |
| `invalid_coords` | coords no numéricas, infinitas o fuera del mapa |
| `invalid_source` | `src` no está conectado o no tiene identificador, o la llamada no viene de otro recurso |
| `rate_limited` | más de 3 llamadas en 10 s por jugador |
| `not_ready` | mdp todavía arrancando |
| `not_owned_vehicle` | no hay fila en `mdp_vehicles` (o está en REMOVED) |
| `not_owner` | el dueño de la fila no es `src` |
| `invalid_state` | ni GARAGED ni OUT |
| `already_out` | ya hay una entidad trackeada con esa matrícula |
| `spawn_failed` | no se pudo crear la entidad (estado restaurado) |
| `locked` | la matrícula está bloqueada por otra operación |

**`RegisterExternalVehicle`** (commit 7de0844): `exports.mdp_garages:RegisterExternalVehicle(netId, plate) -> true | false, err`
- Requisitos:
  - el recurso que llama está en `Config.TrustedResources` (vacío por defecto = export desactivado);
  - la fila se creó hace **< 60 s** (llamar a `AddVehicle(..., 'out')` justo antes);
  - estado OUT y fila no gestionada todavía;
  - entidad sin marcar y sin trackear, y ninguna otra entidad con esa matrícula;
  - la matrícula visible y el modelo coinciden con la fila;
  - entidad de script (population type 7).
- No da llaves ni aplica props: de eso se encarga el concesionario.

| Error | Significado |
|---|---|
| `untrusted_resource` | el recurso que llama no está en `Config.TrustedResources` (o es mdp) |
| `not_ready` | mdp todavía arrancando |
| `invalid_plate` | matrícula no válida |
| `invalid_request` | `netId` no corresponde a un vehículo existente |
| `not_owned_vehicle` | no hay fila (o está en REMOVED) |
| `invalid_state` | la fila no está en OUT |
| `vehicle_mismatch` | ya gestionado, fuera de la ventana de 60 s, ya marcado o trackeado, matrícula duplicada o distinta, modelo distinto o entidad que no es de script |
| `locked` | matrícula bloqueada |

**Adopción en el primer guardado** (fallback si el concesionario no se modifica): `Config.AllowFirstStoreAdoption = true` (valor por defecto).
- Al primer guardado, el dueño (que debe ir conduciendo) adopta un coche sin marcar.
- La fila tiene que estar en OUT, no haber sido gestionada nunca y tener **menos de 30 min**. Límite: 3 adopciones cada 10 min por jugador, con log de auditoría.
- ⚠️ **Hoy solo funciona con filas creadas con `AddVehicle`.** Las filas escritas directamente en `player_vehicles`/`owned_vehicles` llegan por import con `managed_at` fijado y no son adoptables, a la espera de la revisión de Security. Un concesionario sin modificar que **no** llame a `AddVehicle` todavía no queda cubierto.

### 1) Recomendado: `AddVehicle` + `SpawnOwnedVehicle`
El concesionario mantiene su INSERT en la tabla del framework y, además, llama a `AddVehicle(owner, plate, model, nil, 'out')` y **sustituye su spawn** por `SpawnOwnedVehicle`. Las llaves, las props y el combustible los pone mdp.

### 1b) Sin spawn: entrega en garaje
`AddVehicle(owner, plate, model, props, '<garageId>')`, y el jugador lo saca desde la NUI.

### 2) Secundario: `RegisterExternalVehicle` (el concesionario hace el spawn)
```lua
-- shared/config.lua (dueño del servidor): nombre EXACTO del recurso del concesionario
Config.TrustedResources = { 'qbx_vehicleshop' }
```
```lua
-- en el concesionario, justo después de su INSERT y de SU spawn (antes de 60 s desde AddVehicle):
local okA, errA = exports.mdp_garages:AddVehicle(citizenid, plate, model, nil, 'out')
if not okA and errA ~= 'plate_exists' then print(('[shop] mdp AddVehicle %s: %s'):format(plate, errA)) end
-- ... spawn propio del concesionario (CreateVehicleServerSetter / qbx.spawnVehicle) -> netId ...
local ok, err = exports.mdp_garages:RegisterExternalVehicle(netId, plate)
if not ok then print(('[shop] mdp RegisterExternalVehicle %s: %s'):format(plate, err)) end
```
Si `errA == 'plate_exists'` porque la fila ya era antigua, la ventana de 60 s no se cumple y el resultado será `vehicle_mismatch`.

### 3) Último recurso: adopción en el primer guardado
No hay que tocar el concesionario más allá de llamar a `AddVehicle(owner, plate, model, nil, 'out')`. El jugador guarda el coche en menos de 30 min conduciéndolo.

---

### qbx_vehicleshop (Qbox): puntos de enganche ✅
Fuente: https://github.com/Qbox-project/qbx_vehicleshop
- `server/main.lua:164-199`, evento `qbx_vehicleshop:server:buyShowroomVehicle`: cobra, inserta con `exports.qbx_vehicles:CreatePlayerVehicle({ model, citizenid })` (l.188) y llama a `SpawnVehicle(src, { coords, vehicleId })` (l.195).
- `server/main.lua:226-265`, `sellShowroomVehicle`: lo mismo para la venta a otro jugador (`CreatePlayerVehicle` en l.256 y `SpawnVehicle(playerId, …)` en l.261). Los otros flujos que llaman a `SpawnVehicle` (financiación, etc.) siguen el mismo patrón.
- `server/utils.lua:99-124`, `function SpawnVehicle(src, data)`: lee el vehículo con `exports.qbx_vehicles:GetPlayerVehicle(vehicleId)` y hace el spawn con `qbx.spawnVehicle`, `Entity.state.vehicleid` y `config.giveKeys` (`config/server.lua:15`, `exports.qbx_vehiclekeys:GiveKeys(src, vehicle)`). **Es el único sitio que hay que cambiar** para cubrir todos los flujos.

Sustitución recomendada del cuerpo de `SpawnVehicle` (`server/utils.lua`):
```lua
function SpawnVehicle(src, data)
    local coords, vehicleId = data.coords, data.vehicleId
    local newVehicle = vehicleId and exports.qbx_vehicles:GetPlayerVehicle(vehicleId) or data
    if not newVehicle then return end
    local plate = newVehicle.plate or newVehicle.props.plate
    local citizenid = newVehicle.citizenid or exports.qbx_core:GetPlayer(src).PlayerData.citizenid

    local ok, err = exports.mdp_garages:AddVehicle(citizenid, plate, newVehicle.modelName, nil, 'out')
    if not ok and err ~= 'plate_exists' then
        lib.print.error(('mdp AddVehicle %s: %s'):format(plate, err)) return
    end
    local netId, spawnErr = exports.mdp_garages:SpawnOwnedVehicle(plate, coords, src) -- keys/props/fuel by mdp
    if not netId then lib.print.error(('mdp SpawnOwnedVehicle %s: %s'):format(plate, spawnErr)) return end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicleId then Entity(vehicle).state:set('vehicleid', vehicleId, false) end
    TaskWarpPedIntoVehicle(GetPlayerPed(src), vehicle, -1)
    return netId
end
```
⚠️ Sin confirmar: que `GetPlayerVehicle` devuelva `citizenid` y `modelName` en la versión instalada (`modelName` sí se usa en l.107 del original; `citizenid` sale de la consulta de `getPlayerVehiclesInternal` en qbx_vehicles). `coords` es el `vector4` de `GetClearSpawnArea`. El test drive (l.67) **no** debe pasar por mdp: no es un vehículo en propiedad.

### qb-vehicleshop (QBCore): puntos de enganche ✅
Fuente: https://github.com/qbcore-framework/qb-vehicleshop
- `server.lua:294-334`, `qb-vehicleshop:server:buyShowroomVehicle`: `INSERT INTO player_vehicles (…, garage, state)` con `'pillboxgarage', 0` (l.304 y l.319) y después `TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, vehicle, plate)` (l.315 y l.330).
- Mismo patrón en `financeVehicle` (l.339-395, insert en l.356/375 y evento en l.371/390) y en `sellShowroomVehicle` (l.399-430, insert en l.418 y evento en l.428).
- `client.lua:842-855`: el cliente pide `qb-vehicleshop:server:spawnvehicle` (`server.lua:46-70`, `CreateVehicleServerSetter`), aplica las props, `LegacyFuel` y `vehiclekeys:client:SetOwner`, y mete al jugador en el coche.

Sustitución en el servidor, en cada una de las 6 líneas `TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', …)` (`target`/`playerid` en la venta):
```lua
local function mdpDeliver(src, citizenid, vehicle, plate, coords)
    local ok, err = exports.mdp_garages:AddVehicle(citizenid, plate, vehicle, nil, 'out')
    if not ok and err ~= 'plate_exists' then print(('[qb-vehicleshop] mdp AddVehicle %s: %s'):format(plate, err)) return end
    local netId, e = exports.mdp_garages:SpawnOwnedVehicle(plate, coords, src)
    if not netId then print(('[qb-vehicleshop] mdp SpawnOwnedVehicle %s: %s'):format(plate, e)) return end
    TaskWarpPedIntoVehicle(GetPlayerPed(src), NetworkGetEntityFromNetworkId(netId), -1)
end
-- en lugar de: TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, vehicle, plate)
mdpDeliver(src, cid, vehicle, plate, Config.Shops[GetShopForPlayer(src)].VehicleSpawn)
```
⚠️ Sin confirmar: el servidor original no sabe en qué tienda está el jugador (`tempShop`/`insideShop` son variables de cliente, `client.lua:843`), así que `GetShopForPlayer` **no existe** y hay que resolverlo (p. ej. pasando la tienda desde el cliente y validándola por distancia), o usar la alternativa 2 (`AddVehicle(cid, plate, vehicle, nil, 'pillboxgarage')`) y quitar el `TriggerClientEvent`. El `INSERT` original es asíncrono (`MySQL.insert` sin await), pero eso no afecta a mdp.

### esx_vehicleshop (ESX Legacy): puntos de enganche ✅
Fuente: https://github.com/esx-framework/ESX-Legacy-Addons/tree/main/%5Besx_addons%5D/esx_vehicleshop
- `server/main.lua:371-405`, callback `esx_vehicleshop:buyVehicle`: `INSERT INTO owned_vehicles (owner, plate, vehicle)` (l.386) y, dentro del callback del insert, `ESX.OneSync.SpawnVehicle(joaat(model), Config.Zones.ShopOutside.Pos, Config.Zones.ShopOutside.Heading, { plate = plate }, …)` (l.396) + `TaskWarpPedIntoVehicle`.
- `server/main.lua:180-215`, evento `esx_vehicleshop:setVehicleOwnedPlayerId` (venta del concesionario de trabajo): INSERT desde `cardealer_vehicles` (l.212). En este flujo no hay spawn en el servidor, así que conviene usar la alternativa 2 (`AddVehicle(xTarget.getIdentifier(), plate, model, props, '<garageId>')`).

Sustitución del bloque `ESX.OneSync.SpawnVehicle(...)` (l.396-403):
```lua
local okA, errA = exports.mdp_garages:AddVehicle(xPlayer.getIdentifier(), plate, model, nil, 'out')
if okA or errA == 'plate_exists' then
    local pos = Config.Zones.ShopOutside.Pos
    local netId, err = exports.mdp_garages:SpawnOwnedVehicle(plate, vector4(pos.x, pos.y, pos.z, Config.Zones.ShopOutside.Heading), source)
    if netId then
        Wait(300)
        TaskWarpPedIntoVehicle(GetPlayerPed(source), NetworkGetEntityFromNetworkId(netId), -1)
    else
        print(('[esx_vehicleshop] mdp SpawnOwnedVehicle %s: %s'):format(plate, tostring(err)))
    end
else
    print(('[esx_vehicleshop] mdp AddVehicle %s: %s'):format(plate, tostring(errA)))
end
```
`model` es el string del modelo que recibe el callback y `plate` lo genera el servidor (`generateServerPlate`, l.376), así que es fiable.

### Otros concesionarios
- **jg-dealerships**, **okokVehicleShop**: son de pago o escrow. No he verificado públicamente sus puntos de enganche (archivo/función de compra y spawn). ⚠️ Pendiente. Si exponen un hook de "vehículo comprado" en el servidor, aplica el patrón 1 (`AddVehicle` + `SpawnOwnedVehicle`). Si solo hacen el spawn ellos mismos, el patrón 2 (`RegisterExternalVehicle` + `Config.TrustedResources`) o, como último recurso, la adopción en el primer guardado.
