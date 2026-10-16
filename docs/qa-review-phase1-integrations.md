# QA fase 1 — Revisión de Integraciones

- **Commits revisados:** `4bf7b64` (props dirigidas por servidor, llaves al guardar, pound ESX, Sanitize→Security) y `ac77923` (ack negativo determinista). Base `1d13e0e`.
- **Fecha:** 2026-10-16 · Checklist: F1-E, F1-F, F1-H.
- **Sintaxis:** `/tmp/luac54 -p` sobre todos los `.lua` versionados → 0 errores.

## Veredicto: **APROBADO con observaciones** (0 Críticas, 0 Altas)
Las Medias y Bajas se añaden a `docs/backlog-phase1.md` (P1I-*).

## Incidencias
| # | Sev. | Archivo:línea | Descripción / reproducción | Arreglo |
|---|---|---|---|---|
| P1I-M1 | Media | bridge/vehicle/props.lua:136-149 (ACK) | El servidor acepta un NACK `model_mismatch`/`invalid_props` solo porque está en la whitelist; **no repite las comprobaciones** (`docs/integrations.md` dice que sí). Repro: el dueño de red (puede ser otro jugador cercano, no el propietario) envía `propsApplied(netId,false,'invalid_props')` → el coche queda con props por defecto y se avisa de un fallo falso. | En el servidor, comparar `payload.props.model` con `GetEntityModel(p.veh)` y que el payload se pueda decodificar; si no coincide → `LogReject` y seguir esperando el ack. |
| P1I-M2 | Media | bridge/vehicle/framework_sync.lua:98-101 | `OnRelease` (pound = NULL en ESX) no tiene ningún llamador en `server/`. Repro: ESX con columna `pound`, se incauta (se escribe pound) y se libera → `owned_vehicles.pound` queda fijado y los garajes ESX lo siguen viendo en el depósito. | Llamar `MDP.Props.Hook(Bridge.FrameworkSync,'OnRelease',plate)` en la liberación del incautado (Backend). |
| P1I-M3 | Media | server/vehicles.lua:82-85 | Al cambiar de dueño solo se borra `mdp_vehicle_keys`; no se llama a `Bridge.Keys.RemoveKeys` del recurso externo (F1-E «revocadas al cambiar de dueño»). Repro: qb-vehiclekeys, transferencia con el antiguo dueño conectado → sigue con la llave en metadata `vehicleKeys`. | Si el antiguo dueño está online, `Bridge.Keys.RemoveKeys(oldSrc, plate)`. |
| P1I-M4 | Media | server/streamer.lua (P1-M4) | **P1-M4 no lo resuelve Integraciones**: ningún `GiveKeys` en el spawn del streamer. Los coches aparcados siguen cerrados para el propietario con qb-vehiclekeys tras un reinicio y en ESX sin adaptador de llaves. | El que ya está en el backlog: `Bridge.Keys.GiveKeys(ownerSrc, veh)` en el spawn del streamer, o no cerrar sin adaptador. |
| P1I-L1 | Baja | server/garages.lua:259-261 + bridge/keys/qbx_vehiclekeys.lua | `OnStore` se llama **después** de `DeleteEntity`; con qbx (por entidad) `ToEntity(plate)` → nil y `RemoveKeys` devuelve false. Inocuo (qbx liga la llave a `sessionId` de la entidad destruida), pero el log/valor de retorno engaña. | Llamar a `OnStore` antes de `DeleteEntity`, o documentarlo. |
| P1I-L2 | Baja | bridge/vehicle/props.lua (cliente, worker) | Ante un fallo transitorio no se emite `LOCAL_DONE` hasta el `FAIL` final (~10 s); la UI espera. | Aceptable; documentar el tiempo de espera de la UI. |

## Lo que pasó
- Llaves: GiveKeys al sacar (`server/garages.lua:152` → `MDP.Props.GiveKeys`); RemoveKeys al guardar solo en GARAGED, se conservan en PARKED_WORLD; `Config.RemoveKeysOnStore`; con pcall y log. qbx_vehiclekeys `GiveKeys/RemoveKeys(source, vehicle, skipNotification)`, `HasKeys(src, vehicle)` (entidad) y qb-vehiclekeys `GiveKeys/RemoveKeys/HasKeys(id, plate)` revisados de nuevo en el código fuente. Sin adaptador → `true` (la tabla mdp es la fuente de verdad).
- Matrícula: `Bridge.KeysCommon.ToPlate` usa `Utils.NormalizePlate` (cerrado el MEDIA-3 de la fase 0); los globals de la fase 0 se han movido a `Bridge.*`.
- Fuel: la aplicación en el cliente pasa por el adaptador con `Bridge.FuelCommon.Clamp` 0–100; ox_fuel por statebag, LegacyFuel y cdn-fuel solo en cliente y fallback nativo (sin cambios en estos commits).
- Props: statebag `mdp:props` replicado, ack con rate limit, dueño de red y netId validados, un reintento, token anti-temporizadores obsoletos y comprobación de modelo en 32 bits (`joaat` para strings); `Sanitize` delega en `Security.SanitizeProps` con fallback local y límite de tamaño `MAX_JSON`. El evento local `propsApplied` no está en red.
- ESX pound: columna detectada por INFORMATION_SCHEMA, consulta parametrizada, sin cachear errores; nombre de columna fijo (sin inyección).
- Lado cliente/servidor correcto; sin `Wait(0)` nuevos (el worker usa `Wait(100)`, acotado a 5 s); sin globals nuevos.
- Formato de props de ESX, QB y Qbox: los tres usan el formato de ox_lib/`lib.setVehicleProperties`; los alias que faltan siguen en P1-L3 y el saneado del import en P1-L5 (sin cambios).
