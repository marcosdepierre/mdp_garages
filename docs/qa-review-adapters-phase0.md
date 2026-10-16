# QA — Revisión de adaptadores de terceros (fase 0)

Fecha: 2026-10-16 · Revisor: QA · Alcance: `bridge/fuel`, `bridge/keys`, `bridge/notify`, `bridge/billing`, loaders `bridge/*/init.lua`, `fxmanifest.lua`.
Sintaxis: `/tmp/luac54 -p` sobre **todos** los `.lua` del recurso → 0 errores.

## Estado del parche Backend (IssueFine / server/fines.lua)
- `server/fines.lua` (payFine): **APLICADO** — claim atómico 0→2 antes de cobrar (l.24-26), rollback solo `WHERE paid = 2` (l.28, l.37), 2→1 al éxito (l.31); reset de claims huérfanos al arrancar en `server/persistence.lua:42`.
- `Bridge.Billing.IssueFine` (`bridge/billing/init.lua:53-87`): **NO APLICADO / incompleto**. Hay 3 canales, pero sigue usando `'external'` y marcando la multa pagada al enviar (l.74-77), mientras `sql/install.sql:88` ya declara `external = reserved, unused` y añade `needs_review` que el código no usa nunca. El fallback a `internal` (l.81-84) puede generar doble cobro (ver ALTA-1).

## Incidencias

### ALTA-1 — Fallback a `internal` tras SendBill fallido permite doble cobro
- **Archivo:** `bridge/billing/init.lua:71-85` + `bridge/billing/esx_billing.lua:12-14`, `qb-phone.lua:13-17`, `_common.lua:10`.
- **Repro:** `BillPlayer`/INSERT en `phone_invoices` crea la factura, pero `BillingCommon.Link` falla (error de BD tragado por `pcall`) o el adaptador lanza después del INSERT. `HasInvoice` = false → canal `internal`. El jugador paga la multa con `/mdp_payfine` y también paga la factura en esx_billing/qb-phone → dos cobros. El hook `OnPaid` no encuentra el fineId y no hace nada.
- **Arreglo:** `Link` debe devolver boolean y propagarse; si la factura se creó pero no se enlazó → canal `needs_review` (nunca `internal`). Pasar a `internal` solo si es seguro que no se creó factura.

### ALTA-2 — Canal `external` (okokBilling) cierra la multa sin cobro confirmado
- **Archivo:** `bridge/billing/init.lua:74-77`, `bridge/billing/okokBilling.lua:13-15`; prioridad `bridge/billing/init.lua:3`.
- **Repro:** con okokBilling arrancado (primero en la prioridad `auto`, incluso en ESX con esx_billing), se emite multa → `paid = 1` inmediatamente. El jugador rechaza/ignora la factura de okok y el sistema la da por pagada (p. ej. libera incautado). Además `TriggerEvent('okokBilling:CreateCustomInvoice', …)` desde servidor está **no verificado**: la doc lo describe como `TriggerServerEvent` desde cliente; el handler usa `source` (vacío en TriggerEvent) → probablemente la factura no se crea y aun así `SendBill` devuelve `true`.
- **Arreglo:** aplicar parche Backend (no marcar pagado; `needs_review` o mantener `internal`); poner okokBilling al final de la prioridad o desactivarlo hasta tener export/evento de pago verificado; no devolver `true` sin confirmación.

### MEDIA-1 — `OnPaid`: fallo de `MarkFinePaid` no se reintenta ni se registra
- **Archivo:** `bridge/billing/_common.lua:37-40`.
- **Repro:** error de BD durante `esx_billing:paidBill` → el proveedor ya cobró, la multa queda `paid=0` canal `invoice`, no pagable internamente ni cerrable → multa bloqueada para siempre, sin log.
- **Arreglo:** log (siempre, no solo Debug) + marcar `needs_review` o cola de reintento persistida.

### MEDIA-2 — Sin fallback nativo de combustible cuando no hay recurso de fuel
- **Archivo:** `bridge/fuel/init.lua:12-17`, `bridge/fuel/_native.lua` (no registra adaptador).
- **Repro:** sin ox_fuel/cdn-fuel/LegacyFuel, `Bridge.Fuel.Call('GetFuel', nil, veh)` → `nil`; en servidor cdn-fuel/LegacyFuel no se registran, así que también `nil`.
- **Arreglo:** si no se resuelve adaptador, usar `FuelCommon.Get/Set` como implementación por defecto.

### MEDIA-3 — Normalización de matrícula inconsistente en keys
- **Archivo:** `bridge/keys/_common.lua:3-7, 21`.
- **Repro:** `GiveKeys(src, 'ab  12')` → se da llave a `ab  12`; qb-vehiclekeys compara con `Trim(GetVehicleNumberPlateText)` = `AB 12` → el jugador no puede abrir. Contraste con `Utils.NormalizePlate` (upper + colapso de espacios, máx. 8).
- **Arreglo:** usar `Utils.NormalizePlate` + `Utils.IsValidPlate` en `ToPlate`/`ToEntity`.

### BAJA-1 — Globals `FuelCommon`, `KeysCommon`, `BillingCommon`
- **Archivo:** `bridge/fuel/_native.lua:2`, `bridge/keys/_common.lua:2`, `bridge/billing/_common.lua:4`. Checklist §7.
- **Arreglo:** colgarlos de `Bridge` (`Bridge.FuelCommon`, …).

### BAJA-2 — Tipo `'info'` pasado sin mapear a `lib.notify`
- **Archivo:** `bridge/notify/init.lua:18, 27`. ox_lib acepta `inform|success|error|warning`; `'info'` sale con estilo por defecto. Además el `pcall(TriggerClientEvent…)` siempre tiene éxito, por lo que los fallbacks de l.19-21 son código muerto.
- **Arreglo:** reutilizar la tabla `TYPES` de `notify/ox_lib.lua` (o delegar en ese adaptador).

### BAJA-3 — Interfaz de keys no idéntica cliente/servidor ni entre adaptadores
- **Archivo:** `bridge/keys/qb-vehiclekeys.lua:30-36`, `qbx_vehiclekeys.lua:19-26`. En cliente qbx solo acepta entidad (plate string → false), qb acepta ambos. Contrato en `keys/init.lua:11-12` dice entidad O matrícula.
- **Arreglo:** en cliente qbx resolver plate→entidad (o documentar que en cliente solo entidad).

### BAJA-4 — `fxmanifest.lua` carga adaptadores solo-servidor en cliente
- **Archivo:** `fxmanifest.lua:28-29` (`bridge/billing/*.lua` en client_scripts). Retornan pronto, pero se envía código de billing (SQL) al cliente. Mover billing a server_scripts.

### Info — `Wait(0)` en `client/main.lua:69` (fuera del alcance de adaptadores; los adaptadores no tienen ninguno).

## Doble cobro en `_common.lua` (OnPaid) — veredicto
- **Carrera:** correcta. El único yield es el `SELECT` previo; tras él, check+set de `inFlight` es síncrono en Lua, y además `MarkFinePaid` usa `UPDATE … WHERE paid = 0` con `affected == 1`, atómico en BD.
- **Idempotencia:** `MarkFinePaid` se ejecuta como mucho una vez con éxito por fineId; eventos repetidos → no-op.
- **Persistencia tras reinicio:** `done`/`inFlight` son memoria y se pierden, **pero** la idempotencia real persiste por la condición `paid = 0` en SQL; un evento repetido tras reinicio no cambia nada. OK.
- **Limitación:** `OnPaid` solo evita cerrar dos veces; no impide que el dinero se cobre dos veces por dos canales — eso depende de ALTA-1/ALTA-2 (parche Backend pendiente).

## Lo que pasó
- Sintaxis Lua 5.4 OK en todos los archivos.
- Exports/eventos verificados contra fuente real:
  - ox_fuel: statebag `Entity(veh).state.fuel` (sin exports) ✔
  - LegacyFuel: `GetFuel(veh)` / `SetFuel(veh, fuel)` cliente ✔
  - cdn-fuel: `exports['cdn-fuel']:GetFuel/SetFuel`, solo cliente ✔
  - qbx_vehiclekeys: servidor `GiveKeys/RemoveKeys(source, vehicle, skipNotification)`, `HasKeys(src, vehicle)`; cliente `HasKeys(vehicle)` (entidad) ✔
  - qb-vehiclekeys: servidor `GiveKeys/RemoveKeys/HasKeys(id, plate)`; cliente `HasKeys(plate)`, eventos `vehiclekeys:client:SetOwner`, `qb-vehiclekeys:client:RemoveKeys` ✔
  - esx_billing: `BillPlayer(targetId, senderIdentifier, sharedAccountName, label, amount)` → insertedId|false; `esx_billing:paidBill(source, billId)` ✔
  - qb-phone: tabla `phone_invoices`, `qb-phone:RefreshPhone`, `TriggerEvent('qb-phone:server:paidInvoice', source, invoiceId)` ✔
  - ox_lib notify: `lib.notify({description,type})` / evento `ox_lib:notify` ✔
  - okokBilling: evento existe, uso servidor **no verificado** (ALTA-2).
- Detección con `GetResourceState` (`started|starting`) y resolución perezosa; `nil` si falta el recurso; pcall en todas las llamadas a exports con fallback.
- Lado cliente/servidor correcto (fuel cdn/Legacy solo cliente, billing solo servidor, ox_fuel ambos).
- Hooks de pago filtran `GetInvokingResource() ~= RES` y resuelven fineId solo vía `mdp_fine_invoices` (PK `provider, invoice_id`); nunca confían en importes.
- `Bridge.ValidAmount` en todos los SendBill; `FuelCommon.Clamp` 0–100 con NaN.
- Ningún `Wait(0)` en adaptadores.
