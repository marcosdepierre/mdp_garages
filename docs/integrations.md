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
- `mdp_fines.channel` (`Constants.FineChannel`) puede ser `internal`, `invoice`, `external` o `needs_review`. `mdp_fines.paid` (`Constants.FineStatus`) puede ser `UNPAID=0`, `PAID=1`, `CLAIMING=2` o `VOIDED=3`. La anulación usa `paid = VOIDED`, sin columna nueva, y está aislada en `voidFine()` dentro de `server/fine_review.lua`.
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
Constants.FineStatus   = { UNPAID = 0, PAID = 1, CLAIMING = 2, VOIDED = 3 }
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
