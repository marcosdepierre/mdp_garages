# Revisión de seguridad — Fase 1

Revisor: Security Engineer · Base: HEAD `1d13e0e` (16/10/2026) · Ámbito: `server/*.lua`, `shared/*.lua`, `docs/backlog-phase1.md`.

Nota: **el streamer de proximidad aún no existe en el código** (solo se menciona en `server/garages.lua:90`). Lo revisado del spawn es `mdp_garages:takeOut`; los requisitos para el streamer están en la sección final.

## Estado de los callbacks

| Callback | Archivo:línea | RegisterSecureCallback | rateLimit | Propiedad | Distancia |
|---|---|---|---|---|---|
| `mdp_garages:getVehicles` | server/garages.lua:48 | sí (`MDP.Callback`) | 5 / 10 s | lista filtrada por owner/llave en SQL | garaje |
| `mdp_garages:takeOut` | server/garages.lua:77 | sí | 1 / 1 s | owner **o** llave | garaje |
| `mdp_garages:storeVehicle` | server/garages.lua:183 | sí | 1 / 1 s | owner **o** llave sobre `data._plate` (resolvePlate) | garaje + vehículo |
| `mdp_garages:payFine` | server/fines.lua:40 | sí | 2 / 2 s | `owner = ?` en el UPDATE | — |
| `/mdp_payfine` (comando) | server/fines.lua:45 | n/a | `Security.RateLimit` manual | igual que payFine | — |

No hay `RegisterNetEvent` C→S con lógica en `server/`. Los futuros callbacks solo-dueño (dar/quitar llaves, transferir, vender) deben usar `Security.IsOwner(src, plate, false)` dentro del handler (no `requireOwnership`, que acepta llaves).

## Hallazgos

### Critical
Ninguno.

### High

**H1 — Error en el spawn deja el vehículo en OUT sin entidad (no hay rollback)**
`server/garages.lua:133-140`. `CreateVehicleServerSetter` (y `Utils.ModelHash`, `SetVehicleNumberPlateText`, state bags) no van en `pcall`. Si lanzan error (modelo inválido/no streameado, tipo incorrecto), `WithLock` relanza el error y el rollback de la línea 137 no se ejecuta: la fila queda en `state = OUT` sin entidad, y el dueño no puede sacarla (`already_out`) hasta el siguiente reinicio.
*Arreglo:* envolver el spawn en `pcall` y, ante error o timeout, hacer rollback al **estado previo exacto**:
```lua
local okS, veh = pcall(CreateVehicleServerSetter, hash, vtype, spawn.x, spawn.y, spawn.z, spawn.w)
if not okS or not veh or veh == 0 then veh = nil end
-- ...espera...
if not veh or not DoesEntityExist(veh) then
  if veh then DeleteEntity(veh) end
  if state == VS.GARAGED then
    MySQL.update.await('UPDATE mdp_vehicles SET state = ?, garage_id = ? WHERE plate = ? AND state = ?', { VS.GARAGED, row.garage_id, plate, VS.OUT })
  else
    MySQL.update.await('UPDATE mdp_vehicles SET state = ?, coords = ?, parked_at = CURRENT_TIMESTAMP WHERE plate = ? AND state = ?', { VS.PARKED_WORLD, row.coords, plate, VS.OUT })
  end
  return { ok = false, error = 'spawn_failed' }
end
```

**H2 — Props del cliente: obligatorio `Security.SanitizeProps` al guardar**
`server/garages.lua:221-231` (storeVehicle) y `:144` (las props de BD se reenvían por state bag a todos los clientes). El plan de fase 1 es guardar `lib.getVehicleProperties` del cliente. Sin saneado, un cliente puede guardar un modelo distinto, otra matrícula, salud fuera de rango o un blob de varios MB que luego se replica a cada cliente cercano (DoS/crash).
*Arreglo:* en storeVehicle, dentro del `WithLock` y antes del UPDATE:
```lua
local clean, perr, encoded = Security.SanitizeProps(data.props, { plate = plate, model = row.model, mileage = row.mileage }, veh)
if not clean then return { ok = false, error = 'invalid_request' } end -- loguear perr
-- UPDATE ... props = ?  -> encoded
```
Añadir `props = Security.Optional(function(v) return type(v) == 'table' end)` al schema y `mileage` al SELECT de la línea 196.

### Medium

**M1 — takeOut borra la entidad PARKED_WORLD antes del UPDATE condicional**
`server/garages.lua:116-122`. `DeleteEntity(tracked)` va antes de buscar un hueco (`no_spawn`, l.122) y antes de que el UPDATE (l.129-132) confirme la transición. Si no hay hueco o `affected ~= 1`, el coche desaparece del mundo pero la fila sigue en `PARKED_WORLD`.
*Arreglo:* orden: buscar spawn → UPDATE condicional → `affected == 1` → `UntrackSpawn` + `DeleteEntity(tracked)` → spawn nuevo.

**M2 — El rollback de PARKED_WORLD lo mete en el garaje elegido**
`server/garages.lua:129` hace `coords = NULL`, y el rollback de `:137` lo pasa a `GARAGED` en `data.garage_id`. Un coche aparcado en el mundo acaba en el garaje desde el que se intentó sacar (reubicación sin coste). *Arreglo:* incluido en H1 (restaurar `PARKED_WORLD` + `row.coords`).

**M3 — Checks y TrackSpawn de storeVehicle fuera del lock**
`server/garages.lua:205-218`. La detección de clones, el check `state == OUT` y `Security.TrackSpawn` del vehículo no trackeado se ejecutan antes de `WithLock` (l.221). Un `takeOut` concurrente de la misma matrícula puede entrelazarse. *Arreglo:* mover las líneas 196-218 dentro del `WithLock` (releer la fila dentro del lock).

**M4 — Salud del motor/carrocería sin clamp al guardar**
`server/garages.lua:225`, `server/persistence.lua:121, 215, 233, 242`. `GetVehicleEngineHealth` puede valer hasta -4000 (y NaN en entidades rotas); se escribe tal cual y luego la NUI lo muestra como porcentaje. *Arreglo:* `Security.ClampHealth('engine', GetVehicleEngineHealth(veh))` y `Security.ClampHealth('body', ...)`. Decidir con el backend si la BD guarda -4000..1000 o 0..1000 (y documentarlo en architecture.md).

**M5 — payFine: un error después de cobrar devuelve la multa a UNPAID (cobro doble)**
`server/fines.lua:30-34`. Si `RemoveMoney` tiene éxito y luego falla `UPDATE ... paid = 1` (l.27) o el `TriggerEvent`, el `pcall` exterior hace `paid = 0`: el jugador ha pagado y la multa sigue pendiente. *Arreglo:* si el error ocurre tras `RemoveMoney`, dejar la multa en `CHARGING` (la recuperación del arranque la pasa a `needs_review`); usar un flag `charged` local para decidir.

**M6 — Bloqueo por multas comprueba al titular de llave, no al dueño**
`server/garages.lua:69-75, 96`. `unpaidFinesBlocked(src)` busca multas de quien saca el coche. Un dueño con multas puede dar llave a otro jugador y sacar el coche igualmente. *Arreglo:* `owner = row.owner` (añadir `owner` al SELECT de l.86).

### Low

**L1 — `AddVehicle` acepta props de hasta 64 KB sin saneado**
`server/vehicles.lua:245-249`. Fuente server-side (concesionarios), pero el tamaño supera el límite de 16 KB que se replica por state bag. *Arreglo:* `Security.SanitizeProps(props, { plate = plate, model = model })` y usar `encoded`.

**L2 — Props importadas del framework sin límite de tamaño**
`server/vehicles.lua:58, 66`. Se copian `owned_vehicles.vehicle` / `player_vehicles.mods` tal cual. *Arreglo:* saneado o al menos límite de 16 KB antes de la state bag de l.144 de garages.lua.

**L3 — `saveEntityCoords` en `onResourceStop` sin lock**
`server/persistence.lua:8-11, 202`. Riesgo bajo (el UPDATE es condicional a `state = OUT`). Aceptable; documentar.

**L4 — Coords guardadas a partir de la entidad (bien), pero sin validar NaN**
`server/persistence.lua:9-10, 124-125`. *Arreglo:* descartar si alguna coordenada es NaN o |x|,|y| > 10000.

### Backlog fase 1 (items con impacto de seguridad)
- **R6-1** (duplicados en reinicio): **verificado resuelto** en `server/persistence.lua:129-131` y `server/vehicles.lua:100-105` (con ≥1 coincidencia se queda en OUT).
- **R6-2** (`DELETE FROM mdp_vehicle_keys` fuera de `pcall`): sigue abierto; sin impacto de seguridad directo (el borrado de llaves se ejecuta antes del fallo), Baja.

## Requisitos para el streamer de proximidad (aún no implementado)
1. Un spawn por matrícula: todo spawn dentro de `Security.WithLock(plate, 0, fn)`; dentro, `Security.GetSpawnedEntity(plate)` → si existe, no spawnear.
2. Solo filas `state = PARKED_WORLD` (releer dentro del lock); nunca OUT/IMPOUNDED/RETIRED/REMOVED.
3. Coordenadas, heading y modelo **solo desde BD**; props desde BD (ya saneadas al guardar).
4. Spawn con `CreateVehicleServerSetter` en `pcall`; si falla, no tocar el estado y reintentar más tarde (con backoff), sin dejar entidades a medias (`DeleteEntity` si existe).
5. `Security.TrackSpawn(plate, netId, nil)` y state bag `mdp_plate` tras confirmar `DoesEntityExist`.
6. Antes de spawnear, comprobar `Utils.WorldVehiclesByPlate` / `UniqueWorldVehicle` para no duplicar una entidad no trackeada con la misma matrícula y modelo (adoptar en lugar de spawnear).
7. Rate de spawns global (p.ej. N por tick) para evitar picos de entidades.

---

# Re-revisión (16/10/2026, 22:40 UTC+1)

Commits revisados: `e75117f`, `c5a8644`, `f77d546`, `c17d56c` (snapshot de props + tope de km). Líneas referidas a `c17d56c`.

## Estado de los hallazgos

| # | Estado | Evidencia / comentario |
|---|---|---|
| H1 | **Parcial** | `server/props.lua:130-139`: `SpawnVehicle` va en `pcall` y `garages.lua:139-150` hace rollback exacto. Falta una cosa: si `doSpawn` lanza un error **después** de `CreateVehicleServerSetter` (l.106-125: state bags, `RequestApply`), la entidad creada queda en el mundo sin trackear y con la matrícula ya puesta (l.112), y el rollback devuelve la fila a GARAGED/PARKED_WORLD → hay un coche fantasma duplicable. Ver N3. |
| H2 | Corregido | `garages.lua:241-245, 322-323`: `MDP.Props.Sanitize` → `Security.SanitizeProps(props, row, veh, elapsed)` dentro del lock; se guarda el JSON saneado y `COALESCE` conserva las props anteriores si el cliente no manda props. |
| M1 | Corregido | `garages.lua:130-136`: `DeleteEntity` del coche aparcado solo cuando `affected == 1`. |
| M2 | Corregido | `garages.lua:144-147`: el rollback restaura PARKED_WORLD + coords/heading/parked_at y `Streamer.Track`. |
| M3 | Corregido | `garages.lua:201-213, 231-237`: `lockedVehicleChecks` relee la fila, detecta clones y hace `TrackSpawn` dentro del lock. |
| M4 | Corregido | `MDP.Props.Health` → `Security.ClampHealth` en garages, persistence y streamer. El fallback de `props.lua:13-17` usa 0..1000 para el motor (Security usa -4000..1000): unificar (Bajo). |
| M5 | Corregido | `fines.lua`: el flag `charged` deja la multa en CHARGING si el error llega después del cobro. |
| M6 | Corregido | `garages.lua:69-75, 108`: las multas se comprueban por `row.owner`. |
| L1 | Corregido | `vehicles.lua` (AddVehicle): límite de 16 KB + `SanitizeProps`. |
| L2 | Corregido | `vehicles.lua` `capProps`: no se importan props del framework de más de 16 KB; `MDP.Props.Decode` también ignora >16 KB. |
| L3 | Abierto (backlog) | Aceptado. |
| L4 | Corregido | `MDP.Props.ValidCoords` en parkWorld, persistence y streamer. |

**Requisitos del streamer:** se cumplen el 1 (lock + `GetSpawnedEntity`), el 2 (relectura de PARKED_WORLD), el 3 (datos solo de BD), el 4 (pcall + backoff de 2 a 120 s), el 5 (TrackSpawn) y el 7 (5 spawns por tick). El **6 (adopción) queda parcial**: ver N1.

**Snapshot de props (`c17d56c`):** se envía con `TriggerClientEvent` solo al dueño de red (`streamer.lua:138-152`), no por una state bag replicada. El token es de un solo uso (l.172), tiene TTL de 5 s (`Config.SnapshotTokenTtlMs`), se comprueba `NetworkGetEntityOwner(ent) == src` al responder (l.168), la entidad tiene que coincidir (`snap.veh ~= ent`), hay rate limit de 10 por 5 s y las props pasan por `SanitizeProps` dentro del lock. **Bien.** Quedan pendientes N2 y N6.

## Nuevos hallazgos

### High

**N1 — La adopción del streamer acepta cualquier entidad con la misma matrícula y modelo, aunque esté ocupada o lejos**
`server/streamer.lua:82-92` y `:179-186`. Un cliente puede crear su propio coche con el mismo modelo y ponerle la matrícula de un coche aparcado de otro jugador. Si en ese momento el original no está spawneado, el streamer lo adopta (`TrackSpawn` + `mdp_plate`). En el siguiente tick, `becameDriven` ve al conductor, pasa la fila a OUT y hace `ClaimSpawn` para el atacante. Resultado: el atacante se queda con el vehículo «oficial» del dueño (con las props de la BD aplicadas por la state bag) y el dueño ya no puede sacarlo (`already_out`).
*Arreglo:* adoptar solo si (a) `Utils.IsVehicleEmpty(ent)`, (b) `#(GetEntityCoords(ent) - pos) <= Config.ParkedMoveTolerance` (las coords de BD) y (c) la entidad la creó el servidor (`GetEntityPopulationType(ent) == 7` / `NetworkGetEntityOwner` no relevante) o ya tenía `Entity(ent).state.mdp_plate == plate`. Si no se cumple: no adoptar, registrar con `LogReject` y aplicar `fail(plate)`.

**N2 — Cualquier jugador cercano que sea dueño de red puede reescribir las props guardadas del coche de otro**
`server/streamer.lua:103-113` y `:156-174`. El dueño de red de un coche aparcado es el cliente que esté más cerca, no el dueño del coche. Ese cliente puede contestar al snapshot con props arbitrarias dentro de la whitelist (mods, colores, neones, extras), que se guardan en el coche de otro jugador: tuneo gratis al reconectar, o borrar mods/colores para hacer griefing.
*Arreglo:* en el snapshot de despawn, guardar **solo los campos que pueden cambiar con el coche aparcado**: `bodyHealth`, `engineHealth`, `tankHealth`, `dirtLevel`, `windows`, `doors`, `tyres`, `fuelLevel` (con tope ≤ BD). Para todo lo demás (mods, colores, extras, neones, livery, ruedas…), mantener los valores de la BD. Si el dueño de red es el dueño del coche o tiene llave, se puede aceptar todo. Implementación: `local clean = Security.SanitizeProps(...)` → fusionar sobre `MDP.Props.Decode(row.props)` solo las claves de la lista `Security.PropSnapshotFields` (ver abajo).

### Medium

**N3 — Error en `doSpawn` después de crear la entidad deja un coche fantasma**
`server/props.lua:106-139`. Ver H1. *Arreglo:* que `doSpawn` publique la entidad en una variable externa antes de seguir (`created = veh`). En `SpawnVehicle`, si `not ok and created and DoesEntityExist(created)`, hacer `DeleteEntity(created)`.

**N4 — `becameDriven` hace `ClaimSpawn` para cualquier conductor**
`server/streamer.lua:176-188`. Un ladrón (puertas forzadas por otro script) pasa a ser el «dueño» de la sesión del coche. Las políticas de desconexión de `persistence.lua` se aplican entonces con su `src`, y el dueño ve `already_out`. *Arreglo:* hacer `ClaimSpawn` solo si `Security.IsOwner(id, plate)` (dueño o llave). Si no, dejar `src = nil` y registrarlo.

**N5 — Tras un reinicio no hay referencia de tiempo para el tope de km**
`server/props.lua:64-69`. `mileageStamp` está en memoria y `ElapsedSec` devuelve 0 si no hay marca. Los coches adoptados o en OUT después de un reinicio solo pueden sumar 0,5 km al guardar, así que se pierden km reales (es funcional, no un exploit). *Arreglo:* llamar a `StampMileage` también al adoptar (`persistence.lua` en el arranque, `streamer.lua:87-92`) y en `becameDriven`. Si no hay marca, usar `updated_at`/`parked_at` de la fila.

### Low

**N6 — Token generado con `math.random`**
`server/streamer.lua:141`. Lua 5.4 siembra `math.random` al arrancar, pero no es un generador criptográfico. Como el token solo va al dueño de red y además se comprueba `NetworkGetEntityOwner`, el riesgo es bajo. *Arreglo opcional:* combinar con `GetGameTimer()` y un contador, o usar 2×31 bits.

**N7 — Tablas en memoria sin purga**
`server/streamer.lua:18` (`backoff`) solo se limpia con `Forget`, con un spawn correcto o con una adopción. Si una fila sale del registro por `Refresh` (l.41), su entrada sigue ahí. `server/props.lua:64` (`mileageStamp`) nunca se limpia. Ambas crecen como mucho con el número de matrículas (acotado), pero conviene purgar `backoff` en `Refresh` (borrar las claves que ya no estén en `fresh`) y `mileageStamp` en `Forget` / al pasar a GARAGED o IMPOUNDED.

**N8 — Fallback de saneado de props demasiado débil**
`server/props.lua:39-44`. Si `Security.SanitizeProps` no existe, se guardan las props sin whitelist. `security.lua` es un archivo obligatorio del manifest, así que conviene **fallar cerrado**: `return nil, 'invalid_props'`.

**N9 — El despawn sin entrada en el registro borra el coche sin guardar posición ni daños**
`server/streamer.lua:114-131`. Si `registry[plate]` es nil (por una carrera con `Refresh`), `moved`/`damaged` son nil y se borra el coche sin guardar nada. *Arreglo:* si `r == nil`, releer la fila (ya se hace con `snapProps`) y comparar contra ella.

## Firmas acordadas (Security)
- `Security.ClampMileage(plate, oldKm, newKm, elapsedSec) -> km, clamped` (backend: `props.lua:77` ✔).
- `Security.SanitizeProps(props, dbRow, entity, elapsedSec) -> clean|nil, err, json` (backend: `props.lua:34` ✔).
- Nuevo: `Security.PropSnapshotFields`, la lista de campos que un snapshot de un no-dueño puede actualizar (para N2).
