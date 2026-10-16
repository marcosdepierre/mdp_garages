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

---

# Re-revisión 2 (16/10/2026, 22:45 UTC+1)

Commits revisados: `ca4a415`, `078ac23` (backend) y `f6f2495` (frontend, cliente). Los archivos de servidor en HEAD (`5a12ada`) no cambian respecto de `078ac23`.

## Veredicto sobre los bloqueantes de fase 1

| # | Veredicto | Motivo |
|---|---|---|
| **N1** | **ABIERTO — bloquea fase 1** | El criterio de `server/streamer.lua:84-91` (`adoptable`) se puede saltar de dos formas (ver «Evaluación de N1»). Además, la adopción tras reinicio (`server/persistence.lua:107-116`) no aplica ningún criterio de entidad del servidor. |
| **N2** | **Cerrado** | `streamer.lua:124-131` + `:202`: si quien responde no es dueño ni tiene llave, solo se fusionan los campos de `Security.PropSnapshotFields` sobre las props de BD, y el resultado vuelve a pasar por `SanitizeProps` dentro del lock. Detalle menor (N2b, Bajo): si las props de BD no traen `model` (filas importadas del framework), la fusión se rechaza por `model_mismatch` y no se guarda nada (falla cerrado, es seguro). *Arreglo:* `base.model = Utils.ModelHash(row.model)` antes de sanear. |
| **N3** | **Cerrado** | `server/props.lua` (`doSpawn(holder, …)` / `SpawnVehicle`): el handle se guarda en `holder.veh` justo después de `CreateVehicleServerSetter`, y si hay error o timeout se hace `DeleteEntity`. H1 queda así **cerrado**. |

## Estado del resto

| # | Estado | Nota |
|---|---|---|
| N4 | Cerrado | `becameDriven`: `ClaimSpawn` y el paso a OUT solo para dueño o llave; si no, se registra con un throttle de 60 s. |
| N5 | Cerrado | `mileage_ts = UNIX_TIMESTAMP(COALESCE(parked_at, updated_at))` como base cuando no hay marca en memoria, y `StampMileage` al adoptar y en `becameDriven`. |
| N6 | **Parcial** | `props.lua:75` hace `math.randomseed((os.time() ~ (GetGameTimer() << 16)) & 0x7FFFFFFF)`. Esto **empeora** la entropía: reemplaza la semilla aleatoria de Lua 5.4 por una derivada de la hora, que se puede predecir. Ver N11. |
| N7 | Cerrado | `prune`/`Refresh` purgan `backoff` y `driveDenied`, `mileageStamp` tiene `ForgetMileage` + barrido de 24 h, y `snaps` se cierra en `playerDropped`. |
| N8 | Cerrado | `MDP.Props.Sanitize` falla cerrado (`sanitizer_missing`). |
| N9 | Cerrado | `despawnParked` relee la fila de BD y compara contra ella. |
| M4 | Cerrado | `MDP.Props.Health` delega en `Security.ClampHealth`. `078ac23` también lo aplica a la salud importada de QB. |

## Evaluación de N1 (`NetworkGetFirstEntityOwner`)

Fuentes: código de FiveM, `ServerGameState_Scripting.cpp` (`NETWORK_GET_FIRST_ENTITY_OWNER`); docs.fivem.net, «Migrating from other platforms» (entidades huérfanas de `CreateVehicleServerSetter`) y «State Bags»; PR citizenfx/fivem#2257.

1. **`NetworkGetFirstEntityOwner` devuelve `-1` en dos casos:** cuando la entidad no tiene primer dueño (creada por el servidor y todavía huérfana) **y** cuando el primer dueño se desconectó (`firstOwnerDropped`). Un atacante crea el clon con un cliente (o con una cuenta secundaria), le pone la matrícula, se desconecta, y el clon pasa como «creado por el servidor». Encima, una entidad del servidor que ya tuvo un cliente cerca puede tener un primer dueño cliente, así que el criterio también da falsos negativos. **No sirve como prueba de origen.**
2. **`Entity(ent).state.mdp_plate == plate` es falsificable.** Por defecto, el cliente que es dueño de red de una entidad puede escribir state bags **replicadas** de esa entidad (`state:set(k, v, true)`). Solo `sv_stateBagStrictMode true` lo impide, y para todos los scripts. Un cliente crea su coche, le pone `mdp_plate = '<matrícula de otro>'` y pasa la primera rama de `adoptable` (`streamer.lua:87`).
3. `GetEntityPopulationType` tampoco distingue: los vehículos «de misión» creados por un cliente y los del servidor comparten tipo.

### Criterio recomendado (implementado en `server/security.lua`)
- `Security.MarkServerEntity(ent, plate)`: llamarlo **solo** en `MDP.Props.SpawnVehicle`, justo después de que exista la entidad. Guarda el handle en una tabla en memoria y escribe la clave `mdp_srv` en una state bag **no replicada** (`replicated = false`, nunca se envía a clientes) con el valor `joaat(secreto .. ':' .. plate)`. El secreto sale de la convar `mdp_garages_entity_secret` (recomendado: `set mdp_garages_entity_secret "<cadena larga aleatoria>"` en server.cfg, **no** `setr`). Si no existe, se usa un KVP del recurso generado una vez. Los clientes no conocen el secreto: aunque escriban `mdp_srv`, el valor no coincidirá.
- `Security.IsServerEntity(ent, plate)`: en esta ejecución mira la tabla de handles. Tras reiniciar el recurso, la etiqueta secreta sigue en la entidad (las state bags viven con la entidad, no con el recurso).
- `Security.CanAdopt(ent, plate, dbCoords, modelHash, tolerance?) -> ok, reason`: comprueba entidad del servidor, mismo modelo, todos los asientos vacíos y distancia a las coords de BD ≤ `ParkedMoveTolerance`. Motivos de rechazo: `not_server_entity`, `model_mismatch`, `occupied`, `moved`.
- **Si no pasa:** no adoptar nunca. Si está vacía y no es del servidor → `DeleteEntity` (es un clon) + `LogReject` / `OnSuspicious`; si está ocupada → ignorarla y registrarla.
- **Endurecimiento recomendado del servidor (documentar en README/integrations):** `sv_entityLockdown strict` (o `relaxed`) para que los clientes no creen entidades sincronizadas; `sv_filterRequestControl 2` (o `1`) para que no puedan quitar el control de vehículos ocupados; `sv_stateBagStrictMode true` solo si ningún otro script escribe state bags desde el cliente. Atención: `bridge/vehicle/props.lua` no escribe state bags desde el cliente (solo responde con eventos), pero otros recursos del servidor podrían hacerlo. Si la build lo soporta (PR #2257), usar `SetStateBagKeyPolicy` para proteger `mdp_plate`.

### Cambios requeridos al backend para cerrar N1
1. `server/props.lua` (`SpawnVehicle`, tras `DoesEntityExist`): `Security.MarkServerEntity(veh, row.plate)`.
2. `server/streamer.lua:84-91`: reemplazar `adoptable` por `Security.CanAdopt(ent, plate, pos, Utils.ModelHash(row.model))`. Borrar las ramas `mdp_plate` y `NetworkGetFirstEntityOwner`.
3. `server/persistence.lua:107-116` (adopción al arrancar): el mismo `Security.CanAdopt` antes de `TrackSpawn`. Si no pasa, no adoptar (y no borrar si está ocupada).
4. Al despawnear o guardar: `Security.UnmarkServerEntity(veh)` antes de `DeleteEntity` (opcional; hay barrido periódico).

## Nuevos hallazgos (backend)

### High
**N10 — `mdp_plate` replicada y falsificable, usada como señal de confianza en arranque y parada**
`server/persistence.lua:16-20` (`forEachOwnEntity`), `:140` y `:207`. Un cliente puede etiquetar cualquier vehículo suyo con `mdp_plate = '<matrícula de otro>'`. En `onResourceStop`, `saveEntityCoords` (l.8-12) escribe las coords del clon en la fila OUT de la víctima. Al arrancar, l.140 borra entidades etiquetadas que considera huérfanas (borrado de vehículos ajenos). *Arreglo:* `forEachOwnEntity` debe filtrar con `Security.IsServerEntity(veh, plate)` además de `mdp_plate`.

### Low
**N11 — Semilla predecible**
`server/props.lua:75`. Quitar `math.randomseed(...)` (Lua 5.4 ya siembra con hora y dirección de memoria). Mientras siga, los tokens de `NewToken` son más predecibles. El secreto de entidades de `security.lua` se genera **al cargar** el módulo, y si hay convar no usa `math.random`.

**N2b** — ver la tabla del veredicto.

## Revisión del cliente / NUI — `f6f2495` (Frontend)

Eventos y callbacks que dispara el cliente: `lib.callback` `mdp_garages:storeVehicle` y `mdp_garages:parkWorld` (`client/zones.lua`), y `mdp_garages:getVehicles` / `mdp_garages:takeOut` a través de los callbacks NUI de `client/main.lua:69-84`. No añade `TriggerServerEvent` nuevos. El export `GarageToast` es solo local.

| Dato enviado | ¿El servidor confía? | Valoración |
|---|---|---|
| `netId` | No: la matrícula se resuelve en el servidor (`resolvePlate`) | OK |
| `garage_id` | No: se valida el formato y la existencia en config, y la distancia se mide con coords de config | OK |
| `props` | No: `SanitizeProps` (whitelist, modelo = BD y entidad, matrícula del servidor, 16 KB) | OK |
| `fuel` | Parcial: se acota a 0-100 y ≤ BD + 2 | OK |
| `mileage` | No: `ClampMileage` según el tiempo | OK |
| `vclass` | Solo como pista: `Config.VehicleTypes` > `GetVehicleType` del servidor > clase | OK (Bajo: con un `vclass` falso solo cambia el tipo si el servidor no puede resolverlo) |
| Precios / coords | No se envían | OK |
| Matrícula (takeOut) | Normalizada y validada en el cliente **y** en el servidor (schema + propiedad) | OK |

**Rate:** `busy` en el cliente (una petición a la vez) más el rate limit del servidor (1/s para store/park, 5/10 s para la lista). Correcto.

**NUI:** no hay `dangerouslySetInnerHTML`, `innerHTML`, `eval` ni `new Function` en `web/src`. Los toasts renderizan `title`/`description` como texto de React (escapado). Los códigos de error pasan por `Utils.ErrorCode` (whitelist).

### Hallazgos del cliente
- **F1 (Bajo) — `busy` puede quedarse en `true`** (`client/zones.lua`, `storeCurrent` y `/mdp_park`): si `readVehicle`, `GetLabelText` o `toast` lanzan un error antes de `busy = false`, el jugador ya no puede guardar ni aparcar hasta reconectar. Solo le afecta a él (no es un riesgo para el servidor). *Arreglo:* envolver el cuerpo en `pcall` y poner `busy = false` en un único punto final.
- **F2 (Info) — Etiquetas de modelos addon en los toasts:** `GetLabelText` de un vehículo addon puede contener `<`, `>` o `~r~`. Se muestra como texto (sin riesgo XSS); como mucho son códigos de color sin interpretar. Sin acción.

---

# Re-revisión 3 (16/10/2026, 22:50 UTC+1)

Commits revisados: `a8fda43` y `ec0c3b7` (backend, sobre HEAD), y `fecc05a` (F1, cliente).

## Veredicto

| # | Veredicto | Evidencia |
|---|---|---|
| **N1** | **CERRADO** | `server/props.lua` (`doSpawn`): `Security.MarkServerEntity(veh, row.plate)` justo después de confirmar `DoesEntityExist`, antes de la matrícula y de las state bags. `server/streamer.lua` (`spawnParked`): solo se adopta con `Security.CanAdopt(ent, plate, pos, ModelHash)`, con coords de BD; si no pasa y está vacía → `DeleteEntity` + log; si está ocupada → se ignora + log + backoff. `server/persistence.lua:114-137` (arranque): `CanAdopt` con las coords de la fila (`r.coords`); los rechazos se borran si están vacíos o se ignoran si están ocupados (marcados en `dupPlates`, nunca huérfanos), y todo queda en el log. No queda ningún uso de `NetworkGetFirstEntityOwner` ni de `adoptable`/`mdp_plate` como prueba de origen. |
| **N10** | **CERRADO** | `server/persistence.lua:16-23` (`forEachOwnEntity`) exige `Security.IsServerEntity(veh, plate)` además de `mdp_plate`. Por tanto, `saveEntityCoords` al parar y el borrado de huérfanos al arrancar solo afectan a entidades marcadas por el servidor. |
| N11 | Cerrado | `math.randomseed(...)` eliminado de `props.lua`. |
| N2b | Cerrado | `mergeSnapshot` pone `base.model = Utils.ModelHash(row.model)` si las props de BD no lo traen. |
| F1 | Cerrado | `client/zones.lua` (`guarded`): `xpcall`, liberación única de `busy`, timeout de seguridad de 15 s y un token por intento que invalida los resultados tardíos. |
| Docs server.cfg | Correcto | `README.md`: `set mdp_garages_entity_secret`, `sv_entityLockdown`, `sv_filterRequestControl 2`. |

**Fase 1: sin bloqueantes de seguridad abiertos.** Quedan los Bajos de abajo y L3 (backlog).

## Excepción aprobada al arrancar (fila OUT, entidad del servidor ocupada o movida)

Código: `server/persistence.lua:121-127` (`ec0c3b7`). Cada condición, comprobada contra el código:

| Condición | ¿Se cumple? | Dónde |
|---|---|---|
| Estado de BD = OUT | Sí | `st == VS.OUT` |
| `IsServerEntity` = true | Sí | Llamada explícita `Security.IsServerEntity(ent, plate)` (además, `why ∈ {occupied, moved}` implica que `CanAdopt` ya pasó la comprobación de origen) |
| El modelo coincide | Sí | `GetEntityModel(ent) == Utils.ModelHash(r.model)` (y `CanAdopt` comprueba el modelo antes que occupied/moved) |
| Solo occupied/moved | Sí | `why == 'occupied' or why == 'moved'`; `not_server_entity` y `model_mismatch` nunca entran |
| Sin reasignar dueño/llave al conductor | Sí | `TrackSpawn(plate, netId, nil)` (l.142), sin `ClaimSpawn` ni `GiveKeys` en el arranque. Como el `src` queda en nil, `OnPlayerDropped` no aplica políticas por ese conductor. |
| Log con el motivo | Sí | `restart: <plate> adopted despite <occupied|moved> (own server entity, state OUT)` |
| Guardados de posición posteriores con L4 | Sí | `saveEntityCoords` (l.8-12) y la rama park del arranque (l.151) exigen `MDP.Props.ValidCoords`; el streamer y `applyPolicy` también validan. |

**Veredicto: la excepción cumple exactamente las condiciones aprobadas.**

## Nuevos hallazgos (todos Bajos / informativos)

- **R3-1 (Bajo) — Comparación de hash con signo** (`persistence.lua:124`). `GetEntityModel(ent) == Utils.ModelHash(r.model)` depende de que ambos lados usen la misma convención de signo. Hoy coinciden (`ModelHash` normaliza a con signo, igual que `GetEntityModel` en el servidor). *Opcional:* comparar `& 0xFFFFFFFF`, como hace `Security.CanAdopt`.
- **R3-2 (Info) — Entidades sin marca de versiones anteriores.** En el primer reinicio tras desplegar `a8fda43`, las entidades vivas creadas antes no tienen `mdp_srv`. Si están vacías se borran y la fila sigue el flujo normal (OUT → GARAGED, PARKED_WORLD → respawn por el streamer). Si están ocupadas se ignoran. No hay pérdida ni duplicado. Avisarlo en las notas de la versión.
- **R3-3 (Info) — El streamer borra una entidad propia «movida».** Si una entidad del servidor sin trackear se movió más de `ParkedMoveTolerance` (por ejemplo, empujada), el streamer la borra y la vuelve a spawnear en las coords de BD. No hay duplicado; se pierde el desplazamiento. Es aceptable.
- **R3-4 (Info) — Secreto sin convar.** Sin `mdp_garages_entity_secret`, el secreto queda en el KVP del recurso. Cualquiera con acceso a los archivos del servidor puede leerlo (el mismo nivel de confianza que la base de datos). La convar sigue siendo lo recomendado.

---

# Re-revisión 4 — Solo vehículos propios (16/10/2026, 23:10 UTC+1)

Commits revisados: `b17d813`, `f01f58d` (backend), sobre HEAD `169cb30`. La regla y los vectores están en `docs/security.md` §12.

## Contrato del helper (adaptado a la llamada del backend)
`Security.CanStoreOwnVehicle(src, ent, opts) -> ok, plate | false, err[, row]`, con `opts = { plate, row, maxDistance, allowDriver, allowKeys }` (los mismos que pasa `server/garages.lua:251-252`) y, de forma opcional, `states`, `requireDriver` y `requireEmpty`. Errores: `invalid_source`, `invalid_entity`, `not_server_entity`, `plate_mismatch`, `not_tracked`, `not_owner`, `wrong_state`, `model_mismatch`, `too_far`, `not_driver`, `occupied`. El backend mapea los que no conoce a `vehicle_mismatch` (`STORE_ERR`), lo cual es correcto. Nuevo: `Security.RegisterExternalVehicle(netId, plate, ownerSrc?)` para los concesionarios.

## Verificación

| Punto | Veredicto |
|---|---|
| Fallback local equivalente | **Sí** (`garages.lua:211-226`): mismo orden y mismos códigos. Diferencias menores: no revisa `invalid_entity` (ya lo hace `storeTarget`, l.233-244) y mira la propiedad con `IsOwner` en BD en vez de `row.owner` (equivalente). Si `CanStoreOwnVehicle` lanza un error, `pcall` falla cerrado con `not_server_entity`. |
| storeVehicle: comprobaciones antes de efectos | **Sí** (`garages.lua:273-301`): `storeTarget` → en el vehículo → solo el conductor → lock → `lockedOwnVehicle` → y solo entonces el saneado, el UPDATE condicional `state = OUT` y `DeleteEntity`. |
| parkWorld: comprobaciones antes de efectos | **No del todo** → OV-1. |
| Qué se quitó de `f7e1789` | `b17d813` elimina `lockedVehicleChecks` (que **borraba** el clon con el jugador dentro), la aceptación de entidades **no trackeadas** en OUT (R3-1, la vía de los concesionarios) y el guardado desde PARKED_WORLD. La parte de `f7e1789` en `persistence.lua` (P1R3-H1 `keepOut`, `SameModel` en `UniqueWorldVehicle` y en la excepción OUT) **sigue intacta** (`b17d813` no toca persistence ni utils). Sin regresión de P1R3-H1 ni del anti-duplicado del arranque. |
| Quitar el guardado desde el estado 2 | No rompe flujos legítimos. El dueño que se sube a su coche aparcado lo pasa a OUT vía `becameDriven` en ≤ `StreamerTickMs` (1,5 s) y entonces puede guardarlo. Solo falla (`invalid_state`) si intenta guardar antes de ese tick → OV-4 (Bajo, de UX). |
| `/mdp_regularize` | ACE aplicado por FiveM en el servidor (`RegisterCommand(..., true)`); la consola (src 0) siempre puede. Matrícula validada, sin reasignar dueño, sin marcar entidades, con registro. **Pero:** OV-2 y OV-3. |

## Hallazgos

**OV-1 (Medio) — parkWorld ejecuta el auto-impound antes de la comprobación completa**
`server/garages.lua:345-362`. Antes del lock solo se comprueba la marca, que esté vacío, las coords y `IsOwner`. **No** se comprueba el tracking, el estado OUT, el modelo ni la **distancia**. Con el servidor en `MaxWorldParkedServer` y `AutoImpoundOldest` activo, un jugador con un coche marcado propio (aunque esté lejos) puede llamar a `parkWorld` una vez por segundo: cada llamada **incauta el coche aparcado más antiguo de otro jugador** (`freeWorldSlot`) y luego falla con `too_far` dentro del lock. Es griefing masivo.
*Arreglo:* ejecutar `Security.CanStoreOwnVehicle(src, veh, { plate = plate, requireEmpty = true, maxDistance = Config.MaxVehicleDistance })` (solo lectura) **antes** de los límites y de `freeWorldSlot`, y repetirla dentro del lock (ya se hace).

**OV-2 (Medio) — `/mdp_regularize` puede crear un duplicado**
`server/garages.lua:400-411`. El bucle solo mira entidades cuya matrícula **visible** coincide y salta las marcadas. Después solo rechaza si hay una entidad **trackeada**. Una entidad marcada pero **no trackeada** (p.ej. ocupada y rechazada en el arranque → P1R3-H1, fila OUT) o marcada con la matrícula visible cambiada sigue en el mundo, y la fila pasa a GARAGED → el dueño la saca → duplicado.
*Arreglo:* antes de cambiar nada, recorrer **todos** los vehículos y rechazar si alguno cumple `Security.IsServerEntity(ent, plate)` o tiene esa matrícula visible y está ocupado. Hacer esa comprobación primero y borrar después (ver OV-3).

**OV-3 (Bajo) — `/mdp_regularize` borra a medias y acepta cualquier estado**
`server/garages.lua:400-406, 410`. Si encuentra una entidad ocupada a mitad del bucle, devuelve un error **después** de haber borrado otras. Además, el UPDATE pasa a GARAGED cualquier estado distinto de REMOVED, **incluido IMPOUNDED** (salta la multa o tasa del depósito, y la fila de `mdp_impound` queda huérfana) y RETIRED.
*Arreglo:* dos pasadas (comprobar y luego borrar), `WHERE plate = ? AND state = ?` con OUT (o PARKED_WORLD), rechazar IMPOUNDED/RETIRED, y registrar el identificador del admin (no solo el src).

**OV-4 (Bajo, UX) — Guardar justo al subirse a un coche aparcado**
Entre subirse y el siguiente tick del streamer, la fila sigue en PARKED_WORLD → `invalid_state`. *Arreglo opcional:* que la NUI muestre «inténtalo de nuevo en un momento», o que `storeVehicle` llame a `becameDriven` (con las mismas comprobaciones de dueño y lock) antes de validar.

**OV-5 (Medio, funcional) — Los concesionarios ya no pueden guardar sus coches**
Al quitar la aceptación de entidades no trackeadas en OUT, los vehículos entregados por un concesionario con `AddVehicle(..., 'out')` no se pueden guardar ni aparcar. *Arreglo:* `exports('RegisterExternalVehicle', function(netId, plate) return Security.RegisterExternalVehicle(netId, plate) end)` en el servidor y documentarlo en `docs/integrations.md`. La heurística (`AllowFirstStoreAdoption`) queda desactivada por defecto (§12 de security.md).

**OV-6 (Info) — `Config.AllowSharedKeyStore`**
Reservado y false por defecto. Si se activa, contradice el requisito de Marcos (solo dueño); tendría que decidirse explícitamente en la fase 3.

## Veredicto
El requisito «solo vehículos propios» queda **cumplido en storeVehicle**. En **parkWorld** queda cumplido para guardar/aparcar, pero tiene el efecto secundario previo OV-1, que hay que arreglar antes de cerrar. `/mdp_regularize` necesita OV-2 antes de usarse en producción.

---

# Re-revisión 5 — Adopción en el primer guardado, exports de concesionario y filas importadas (16/10/2026, 23:20 UTC+1)

Commits revisados: `53c2c56` (SpawnOwnedVehicle), `7de0844` (adopción en el primer guardado, RegisterExternalVehicle, esquema v5 `managed_at`) y `7ad284c` (filas importadas: `mdp_synced_owners`, `mdp_meta.initial_import_done`, guarda `IsTrackedEntity`).

## Nuevo en security.lua
`Security.IsTrackedEntity(ent) -> plate|nil`. Usa un índice inverso `netId → plate` que mantienen `TrackSpawn` (al re-trackear desvincula la entidad anterior; un netId solo puede representar una matrícula), `UntrackSpawn` y `GetSpawnedEntity` (al limpiar entradas obsoletas). `ClaimSpawn` y la limpieza de `playerDropped` conservan el netId (solo cambian `src`). Comprueba que la entidad siga existiendo y que `NetworkGetEntityFromNetworkId(netId) == ent`. `PlateOfEntity` y `RegisterExternalVehicle` ya lo usan (O(1)).

## Política de adopción (los 7 puntos) frente a `7de0844` + `7ad284c`

| # | Punto | Estado | Dónde / nota |
|---|---|---|---|
| 1 | Rechazar si tiene cualquier marca mdp o está trackeada para otra matrícula | **Parcial** | `garages.lua` `adoptUnmarked`: `IsTrackedEntity(ent)` (cualquier matrícula) + `mdp_plate` + `IsServerEntity(ent, plate)` + `GetSpawnedEntity(plate)`. Falta `mdp_srv` **de otra matrícula** → AD-3. |
| 2 | `GetEntityPopulationType == 7` | Cumple | |
| 3 | Ventana de 30 min desde la creación de la fila | Cumple | Constante `ADOPT_WINDOW_MIN = 30` (no configurable); `created_at` NULL → nunca. |
| 4 | Props de BD/stock + solo `PropSnapshotFields` | Cumple | `adoptionProps`, y después pasa por `SanitizeProps`. |
| 5 | Un solo uso (`managed_at`), rate limit y auditoría | Cumple | UPDATE condicional `managed_at IS NULL` con deshacer si pierde la carrera; 3 cada 10 min por jugador; `AUDIT adopt …`. |
| 6 | Dueño = jugador, misma matrícula y modelo, fila nunca gestionada, sin otra entidad viva, jugador al volante | Cumple | Recorrido del pool por matrícula visible; `requireDriver`. Solo en `storeVehicle`; `parkWorld` rechaza la adopción. |
| 7 | Mitigaciones fijas en el código, no configurables | Cumple, **pero** el interruptor general `Config.AllowFirstStoreAdoption` vale **`true`** por defecto (`shared/config.lua`), cuando la política dice `false` → AD-1. |

**Orden del flujo** (`storeVehicle`): `storeTarget` (si hay marca demostrada → ruta normal; si no hay marca y existe fila → candidata a adopción) → rate limit de adopción → lock → `adoptUnmarked` (marca + tracking + `managed_at`) → `lockedOwnVehicle` / `CanStoreOwnVehicle` con los 7 puntos completos → efectos. **Correcto.** Rechazar cuando `IsTrackedEntity` devuelve *cualquier* matrícula, incluida la misma, también es correcto: una entidad trackeada y marcada para esa matrícula nunca llega a la adopción (va por la ruta normal en `storeTarget`). Una trackeada **sin** marca (heredada) no debe adoptarse, sino regularizarse (`/mdp_regularize`).

## RegisterExternalVehicle (export, `7de0844`)
Cumple la política: `Config.TrustedResources` contrastado con `GetInvokingResource()` (lista vacía = export desactivado; nunca el propio recurso), fila creada hace < 60 s (fijo), estado OUT, `managed_at` NULL, entidad sin marca ni tracking, sin otra entidad viva con la matrícula, misma matrícula y modelo, tipo de población 7, con lock y auditoría. Nota: `Security.RegisterExternalVehicle` (security.lua) es la primitiva de bajo nivel, **sin** las comprobaciones de recurso de confianza ni de ventana. No debe exportarse directamente: el export del backend es la vía autorizada.

## Backfill de `managed_at` (v5)
Se ejecuta una sola vez, al crear la columna: `managed_at = updated_at` para filas con estado 1/2/3, con props o coords, con `source = 'framework'`, con `created_at` NULL o con más de 30 min. Las importaciones nuevas entran con `managed_at = NOW()` salvo la excepción de `7ad284c`. Solo quedan NULL las filas `mdp` en OUT, sin props ni coords y con menos de 30 min (exactamente las entregas recientes de concesionario). **Correcto.**

## Filas importadas (`7ad284c`)

| Requisito | Estado |
|---|---|
| Solo sincronización incremental (`initial_import_done` + dueño en `mdp_synced_owners`) | Cumple (`vehicles.lua` `syncPlayer`, `adoptable = initialDone and known`) |
| Primera sincronización por identificador → `NOW()` | Cumple (el dueño se añade después de su primera sincronización) |
| `mdp_migrate` y todo lo anterior al flag → `NOW()` | Cumple (`ImportFromFramework` sin `opts` → `NOW()`; el flag se pone tras `SyncConnectedPlayers` en el arranque, o en el upgrade si había dueños) |
| Solo OUT (ESX `stored=0`, QB `state=0`), nunca GARAGED | Cumple (`r.state == VS.OUT` después de R4-1, que pasa a GARAGED las OUT sin entidad viva) |
| Ventana de 30 min sobre la columna de fecha del framework | **Parcial** → AD-2 |
| Siembra de dueños existentes en el upgrade | Cumple (solo si la tabla no existía) |

## Hallazgos

**AD-1 (Medio) — La adopción en el primer guardado está activada por defecto**
`shared/config.lua`: `Config.AllowFirstStoreAdoption = true` (y el alias legado también es `true` por defecto). La política exige `false`; la vía preferida es `RegisterExternalVehicle`. *Arreglo:* que el valor por defecto sea `false` (también en `adoptionEnabled()` cuando el valor es nil).

**AD-2 (Medio) — Ventana de fecha del framework: NULL y fechas futuras la abren**
`vehicles.lua` `InsertBatch`: `r.fwCreatedTs == nil or (os.time() - ts) <= 1800`.
- (a) Si la tabla **tiene** columna de fecha pero el valor es NULL (o `UNIX_TIMESTAMP` devuelve NULL por un formato raro), cuenta como «sin ventana» → adoptable.
- (b) Una fecha **futura** (desfase de zona horaria si el framework escribe la hora local como texto, o un reloj desajustado) da un delta negativo y pasa el `<= 1800` → adoptable durante horas.
- (c) Si la columna es un INT con epoch o un VARCHAR, `UNIX_TIMESTAMP()` da 0 o NULL → caso (a).

*Arreglo:* distinguir «la tabla no tiene columna» de «valor NULL» (con columna y valor NULL → **no** adoptable). Exigir `-300 <= os.time() - ts <= 1800` (5 min de margen por desfase). Si la columna no es DATETIME/TIMESTAMP (`information_schema.columns.DATA_TYPE`), ignorarla y registrar un aviso al detectarla.

**AD-3 (Bajo) — Marca `mdp_srv` de otra matrícula**
`garages.lua` `adoptUnmarked`: `IsServerEntity(ent, plate)` solo detecta la marca de **esta** matrícula. Una entidad marcada para X, sin trackear (caso P1R3-H1) y con la state bag `mdp_plate` borrada por su dueño de red, puede adoptarse como Y si Y es una fila propia en la ventana. *Arreglo:* rechazar si `Entity(ent).state.mdp_srv ~= nil` (cualquier valor) o si `Security.PlateOfEntity(ent) ~= nil`.

**AD-4 (Medio) — `SpawnOwnedVehicle` desde OUT puede duplicar**
`garages.lua` (`53c2c56`): con el estado OUT solo comprueba `GetSpawnedEntity(plate)`. Si existe una entidad viva **sin trackear** con esa matrícula (P1R3-H1 `keepOut`, o un coche del concesionario aún sin registrar), se crea otra → duplicado. *Arreglo:* en OUT, recorrer el pool (`Utils.WorldVehiclesByPlate()[plate]`) y devolver `already_out` si hay alguna entidad con esa matrícula. Además, restringir el export a `Config.TrustedResources` como `RegisterExternalVehicle` (hoy lo acepta cualquier recurso; Bajo).

**AD-5 (Bajo) — Renombrar la columna de fecha del framework**
`frameworkDateCol` se cachea por tabla durante toda la ejecución. Si la columna se renombra o se borra en caliente, la SELECT con `UNIX_TIMESTAMP(\`col\`)` falla → `okQ = false` → la sincronización de ese dueño falla hasta reiniciar (no abre la adopción; falla cerrado). *Arreglo:* si la consulta falla, vaciar `dateColCache[tbl]` y reintentar una vez sin la columna.

**AD-6 (Info) — Dueño que nunca se sincronizó**
Primera sincronización = no adoptable, y luego pasa a ser conocido. `mdp_migrate` no añade dueños a `mdp_synced_owners`, así que tras migrar su primera sincronización tampoco es adoptable (conservador, correcto). Si `SyncConnectedPlayers` falla a medias en el arranque, `initial_import_done` se marca igual. Las filas de los no sincronizados siguen sin ser adoptables (lo protege `known`), así que no hay riesgo.

## Veredicto
Los requisitos de adopción y del export se cumplen salvo **AD-1** (valor por defecto) y **AD-2** (ventana de fecha), que hay que arreglar antes de cerrar la fase 1, y **AD-4** (duplicado en `SpawnOwnedVehicle`). AD-3, AD-5 y AD-6 son Bajos o informativos.

---

# Re-revisión 6 — commit `677f577` (16/10/2026, 23:15 UTC+1)

## Verificación de los arreglos de la re-revisión 5
| ID | Estado | Comprobación |
|---|---|---|
| AD-1 | Pendiente (no incluido en el commit) | `Config.AllowFirstStoreAdoption` sigue a `true`. Lo rebajo a Bajo: las mitigaciones 2-7 son fijas y AD-2/AD-3 ya están cerrados. Recomiendo `false` por defecto antes del release. |
| AD-2 | **Cerrado** | Solo `datetime`/`timestamp` (`information_schema.DATA_TYPE`); `fwHasDate` sin valor → no adoptable; se exige `-300 <= age <= 1800`. Además `created_at <= NOW()` en la ventana mdp (M5). |
| AD-3 | **Cerrado** | `adoptUnmarked` rechaza si `IsTrackedEntity` devuelve una matrícula (cualquiera), si `PlateOfEntity`, si existe `mdp_plate` o `mdp_srv ~= nil`, si `IsServerEntity` o si `GetSpawnedEntity(plate)`. |
| AD-4 | **Cerrado** | `liveEntityConflict` recorre el pool en `takeOut` (excluyendo la entidad aparcada trackeada) y en `SpawnOwnedVehicle`; los dos exports pasan por `isTrusted` (nunca nuestro propio recurso). |
| AD-5 | **Cerrado** | Si la consulta falla: olvida la columna, reintenta una vez sin ella y fuerza `adoptable = false`. |
| Rate limit de RegisterExternalVehicle | OK | 10 llamadas / 60 s por recurso, con ventana fija. |
| Nombres de opts | **Coinciden exactamente** | `allowDriver`, `allowKeys`, `states`, `requireDriver`, `requireEmpty`, `maxDistance`, `plate`, `row` = los que lee `Security.CanStoreOwnVehicle`. Mapeo de errores `not_driver`/`occupied`/`invalid_*` correcto. |
| M2 `/mdp_regularize` | OK | Rechaza los estados 3/4 y las multas impagadas. |

## Transferencias y revocación de llaves (P1-OWN-H1)
Bien resuelto:
- `ApplyTransfer` es atómico (`UPDATE … WHERE owner = old AND state <> 5` y comprueba `n == 1`). Una transferencia concurrente pierde y no hace nada.
- Se aplica en cualquier estado vivo. No permite autotransferirse la propiedad: el nuevo dueño viene de la tabla del framework, o de `AddVehicle`, que valida el `owner` (string, de 1 a 64) y la matrícula.
- Dentro del lock de guardar/aparcar se compara con el dueño del framework; si no coincide, `not_owner` y se resincroniza.
- La entidad sigue trackeada y la reclama el comprador.

### Hallazgos
**TR-1 (Medio) — TOCTOU entre la transferencia y take-out/store/park.** `ApplyTransfer` se ejecuta **fuera** del lock de la matrícula (sync/`AddVehicle`). Los UPDATE de estado de `takeOut` (`garages.lua:138/141`), store (`:455`) y park (`:501`) solo condicionan `state`, no `owner`. El vendedor puede pasar la comprobación de dueño dentro de su lock, que entre la transferencia, y que su take-out siga adelante: saca el coche ya vendido y su entidad queda trackeada a su nombre. *Arreglo (cualquiera de los dos):* añadir `AND owner = ?` (`row.owner`) a esos UPDATE y tratar `affected == 0` como `not_owner`; o ejecutar `ApplyTransfer` dentro de `Security.WithLock(plate, nil, …)`, si el lock lo permite (lo preferible son las dos cosas).

**TR-2 (Medio) — Revocación incompleta de llaves temporales o de puente.** `RemoveKeys` solo se llama al **vendedor online**. Las llaves temporales, compartidas o de puente que otros jugadores tienen en el recurso de llaves (qb-vehiclekeys, qs, wasabi…) y las del vendedor desconectado en recursos con persistencia no se revocan. *Arreglo:* recorrer los jugadores online y llamar a `Bridge.Keys.RemoveKeys(s, ent or plate)` para cada uno salvo el comprador. Si el bridge lo expone, usar `Bridge.Keys.RevokeAll(plate)`. Documentar que la persistencia offline depende del recurso de llaves.

**TR-3 (Bajo) — Fallos silenciosos.** El `DELETE` de `mdp_vehicle_keys` va dentro de un `pcall` y su error se ignora: la transferencia queda aplicada con las llaves vivas y sin rastro. *Arreglo:* registrar el error y reintentar, o hacer el DELETE y el UPDATE en una transacción (`MySQL.transaction.await`).

**TR-4 (Bajo) — Coherencia con el framework.** `FrameworkOwner` usa `UPPER(TRIM(plate)) … LIMIT 1`. Si hay dos filas del framework que se normalizan igual, el dueño es arbitrario y puede alternar en cada guardado. *Arreglo:* si hay más de un resultado, no transferir y registrarlo (`framework_plate_ambiguous`). Validar también que `fwOwner` sea un string no vacío de 64 caracteres como máximo antes de `ApplyTransfer`.

**TR-5 (Bajo) — Autotransferencia y auditoría.** `ApplyTransfer(plate, X, X)` coincide con una fila (oxmysql cuenta las filas encontradas) y revoca todas las llaves (DoS menor desde `AddVehicle`). *Arreglo:* `if oldOwner == newOwner then return false end`. El registro es solo `print`: usar `Security.Log('AUDIT', 'transfer', …)` (con la matrícula, el dueño anterior, el nuevo y el origen: sync, add o lock).

## Veredicto
No quedan bloqueantes Críticos ni Altos. N1, N10, P1-OWN-H1/H2 y AD-2 a AD-5 están cerrados.
Antes de cerrar la fase 1 hay que arreglar **TR-1** (UPDATE condicionados al dueño; es pequeño) y **TR-2** (revocar las llaves a todos los jugadores online). Son Medios, pero afectan directamente a la regla «solo vehículos propios». Con esos dos aplicados, la fase 1 puede cerrarse en el plano de seguridad; AD-1 y TR-3 a TR-5 pueden ir a la fase 2.

---

# Re-revisión 7 — `2b60c36`, `bb6397a`, `ad7f0e5` (16/10/2026, 23:20 UTC+1)

## Nuevo en security.lua: `Security.Log(level, category, msg, fields)`
- Niveles: `AUDIT`, `ERROR` y `WARN` se imprimen **siempre**, sin depender de `debug`. `INFO` y `DEBUG` solo se imprimen con `debug`. Un nivel desconocido se trata como `INFO`.
- Saneado: sin caracteres de control, sin códigos de color `^n` y sin `<`/`>`. Valores recortados a 128 caracteres, mensaje a 256 y como máximo 24 campos (`_truncated`). Las tablas aparecen como `[table]`.
- Hook `Security.OnLog(entry)`, con `{ level, category, msg, fields, time }`, sobrescribible para webhooks. Se llama siempre (también para `DEBUG`), y sus errores se capturan.
- **Backend (TR-5):** sustituir el `print` de `onOwnerChanged` por `Security.Log('AUDIT', 'transfer', 'owner changed', { plate = plate, old = oldOwner, new = newOwner, via = 'sync'|'add'|'lock' })`. Lo mismo para `adopt`, `regularize` y `external`.

## Verificación de la re-revisión 6
| ID | Estado | Nota |
|---|---|---|
| TR-1 | **Cerrado** | Todos los UPDATE de estado (takeOut ×2, store, park, SpawnOwnedVehicle) llevan `AND owner = ?`; 0 filas → `not_owner`; el UPDATE va antes del spawn. takeOut revalida `IsOwner` dentro del lock. **`WithLock` no es reentrante** (un segundo `Lock` sobre la misma matrícula devuelve `false` → `'locked'`). La reutilización se hace bien: `ApplyTransfer(..., locked=true)` solo desde `lockedOwnVehicle`, que ya tiene el lock, así que no hay deadlock. Las llamadas sin lock (sync, AddVehicle) usan `WithLock(plate, 0, …)`: si la matrícula está ocupada, la transferencia no se aplica (falla cerrado; la sync la reintenta y el control del framework dentro del lock la cubre). Ver R7-3. |
| TR-2 | **Cerrado** (para jugadores online) | `RemoveKeys` a todos los online salvo el comprador, más el DELETE de `mdp_vehicle_keys`. Las llaves offline persistentes dependen del recurso de llaves (documentado). |
| TR-3 | Parcial (aceptado) | Se registra el error; la transacción queda para la fase 2. |
| TR-4 | **Cerrado** | `LIMIT 2`; con más de una fila → `nil, 'ambiguous'`, sin transferencia; el dueño se valida como string no vacío. Ver R7-2. |
| TR-5 | **Cerrado** | Guarda `old == new` y `newOwner` válido. AUDIT: ya existe `Security.Log`. |
| R2-M1 | OK | Con la fila GARAGED se ignoran los clones sin marca: el coche real sale marcado y el clon nunca puede guardarse (no tiene marca). Evita bloquear al dueño. |
| R2-M3 | OK | Parámetros enlazados (`?`), sin concatenación; la matrícula ya está validada (`[A-Z0-9 ]`, sin comodines); el padding solo se aplica si tiene menos de 8. Con colaciones PAD SPACE las dos condiciones encuentran la misma fila (no hay duplicado falso). |

## first_seen_at / fw_date_at (`bb6397a` + `ad7f0e5`)
- **Lo escribe solo el servidor y nunca se actualiza:** solo aparece en el `INSERT IGNORE` de `InsertBatch` (`NOW()`, y `FROM_UNIXTIME(%d)` con un entero, sin inyección). Ningún UPDATE lo toca. ✓
- **Nunca en la importación inicial, la primera sincronización ni `mdp_migrate`:** esas rutas insertan `managed_at = NOW(), first_seen_at = NULL`. Las filas existentes al migrar a v6 quedan NULL. ✓
- **NULL = no adoptable:** `first_seen_at IS NOT NULL` obligatorio. ✓
- **Sospecha del bug de `bb6397a`: confirmado.** La ventana empezaba en `GREATEST(first_seen_at, fw_date_at)`, el más tardío. Un coche comprado 29 min antes de la detección seguía siendo adoptable hasta casi una hora después de la compra.
- **Arreglado en `ad7f0e5`:** `TIMESTAMPDIFF(SECOND, LEAST(first_seen_at, COALESCE(fw_date_at, first_seen_at)), NOW()) <= windowSec`, y cada fecha presente con `>= -300` (como máximo 5 min en el futuro). Es la regla correcta (expira en min + ventana). ✓ No reabre AD-2.
- **RegisterExternalVehicle (60 s):** mismo cálculo con un tope de 60 s desde la fecha más temprana. Efecto colateral (funcional, no de seguridad): una fila del framework solo se detecta en la sincronización del dueño (al cargar, o cada 60 s al abrir el garaje), así que el concesionario que llame al export justo tras la compra suele recibir `not_owned_vehicle`. Falla cerrado. Recomendación: que los concesionarios usen `AddVehicle` antes (filas `mdp`, ventana por `created_at`).
- **Vector de borrar y reinsertar:** **no reabre la ventana.** Si el framework borra la fila → `SyncRemovals` la pasa a REMOVED (soft delete). Al reinsertarla → restauración por UPDATE que **no toca** `first_seen_at` (conserva la fecha original, ya caducada). Con `SyncRemovals` desactivado la fila mdp sigue ahí (`e` existe) y no hay INSERT. Solo un borrado **manual** (DELETE en BD por un admin) generaría un `first_seen_at` nuevo (Info; documentar que no se borren filas de `mdp_vehicles` a mano).

## Otras comprobaciones pedidas
- **Tasa de depósito («quien recoge paga»):** la liberación de pago no existe todavía (takeOut devuelve `impounded`; fase 5). Requisito para la fase 5: `releaseImpound` debe exigir **dueño** (`IsOwner(src, plate, false)`, más el control del dueño del framework dentro del lock) antes de cobrar. Pagar la tasa nunca puede dar derecho a sacar el coche de otro. La tasa se lee de `mdp_impound`, nunca del cliente (ya está así en architecture.md).
- **Multas que se quedan con el infractor:** `unpaidFinesBlocked(row.owner)` y `/mdp_regularize` solo cuentan las multas del dueño **actual**. El comprador no queda bloqueado por las del vendedor ✓. El vendedor no las esquiva: siguen ligadas a su identificador y le bloquean sus demás vehículos. Vender a una cuenta alternativa libera ese coche concreto, pero la deuda sigue en el vendedor (es la política de diseño; Info: auditar las transferencias con `Security.Log`).

## Hallazgos
**R7-1 (Alto, coincide con QC `3d6077a`) — takeOut y SpawnOwnedVehicle no comparan con el dueño del framework.** `FrameworkOwner` solo se llama en `lockedOwnVehicle` (store/park, `garages.lua:374`). Si el framework cambia de dueño y la sincronización todavía no ha corrido (caché de 60 s, vendedor sin reconectar), el vendedor puede sacar del garaje el coche ya vendido. *Arreglo:* dentro del lock de takeOut y SpawnOwnedVehicle, con `SyncFrameworkTables`, `fwOwner = FrameworkOwner(plate)`; si no coincide → `ApplyTransfer(plate, row.owner, fwOwner, true)` y `not_owner`. Si devuelve `'ambiguous'` → rechazar (ver R7-2).

**R7-2 (Bajo) — Ambigüedad = control omitido.** Con `FrameworkOwner → nil, 'ambiguous'` (o una fila no encontrada por espacios iniciales), `lockedOwnVehicle` continúa con el dueño de mdp. *Arreglo:* con `'ambiguous'` → falla cerrado (`not_owner`, y registrarlo con `Security.Log('WARN', 'ownership', …)`).

**R7-3 (Bajo) — `AddVehicle` con la matrícula bloqueada** devuelve `transfer_failed` (indistinguible de un fallo real). *Arreglo:* propagar `'locked'` → `busy` para que el concesionario reintente.

## Veredicto
No quedan Críticos. Hay **un Alto: R7-1** (control del dueño del framework en takeOut/SpawnOwnedVehicle, el mismo que reporta QC en `3d6077a`). **La fase 1 NO está cerrada en el plano de seguridad hasta aplicar R7-1.** Es un arreglo pequeño que reutiliza el patrón de `lockedOwnVehicle`. Con R7-1 aplicado y verificado, la fase 1 queda cerrada; R7-2, R7-3, AD-1 y TR-3 pueden ir a la fase 2.

## Añadido a la re-revisión 7: `e10f763` y marca HMAC

### `e10f763` — control común del dueño del framework, `duplicate_plate`, adopción del clon marcado al reiniciar
- **`checkFrameworkOwner`** se llama dentro del lock en **takeOut, store/park (`lockedOwnVehicle`) y SpawnOwnedVehicle**. Si no coincide → `ApplyTransfer(…, locked=true)`, reutilizando el lock sin deadlock, y `not_owner`. Con `'ambiguous'` → `duplicate_plate`, falla cerrado y aviso al admin. **R7-1 cerrado. R7-2 cerrado.**
- **Adopción al reiniciar:** si hay varias entidades con matrícula y modelo coincidentes, solo se adopta la **única** que pasa `IsServerEntity`. Los clones sin marca se borran si están vacíos y se ignoran si están ocupados. Con 0 o 2+ marcadas no se adopta ninguna y la fila queda OUT. Correcto: nunca se adopta una entidad del cliente. Nota: con la nueva marca HMAC, en el primer reinicio tras actualizar no hay marcas válidas, así que se cae en «ninguna adoptada» (el mismo efecto que R3-2, ya en las notas de versión).
- **P1-OWN-M1** (sin entidad marcada → la fila queda OUT y el dueño no puede recuperar su coche) **queda para la fase 2** con un diseño de «recover»: borrar los clones vacíos sin marca y crear un coche nuevo y marcado desde el servidor (con lock, `AND owner = ?` y pasando por el recorrido del pool). **Nunca adoptar una entidad del cliente.**

### Marca de entidad: joaat → HMAC-SHA256 (security.lua)
- **Problema:** `joaat(secret .. ':' .. plate)` da 32 bits y, tras el prefijo secreto, el estado interno de one-at-a-time también es de 32 bits. Con un solo par (matrícula, marca) filtrado se puede continuar el hash y falsificar la marca de cualquier matrícula, y además es atacable por fuerza bruta.
- **Arreglo:** SHA-256 y HMAC-SHA256 en Lua 5.4 puro (enteros nativos, `>>`, `<<`, `~`, `&`, `string.pack`). La marca es `hex(HMAC(secret, 'mdp_srv:' .. plate))[1..32]` (128 bits). La comparación es en tiempo constante (`ctEqual`). Las firmas de `MarkServerEntity`, `IsServerEntity` y `UnmarkServerEntity` no cambian. Las primitivas se exponen en `Security.Crypto` (`sha256`, `hmacSha256`, `toHex`, `ctEqual`).
- **Tests:** SHA-256 de `''` y `'abc'`, y los vectores de RFC 4231 1, 2, 3, 4, 6 y 7 (incluida una clave mayor que el bloque). La marca tiene 32 hex, está ligada a la matrícula, se valida tras un «reinicio» (sin memoria) y se rechaza un valor joaat antiguo.
- **Fugas:** la marca se escribe con `state:set(SRV_KEY, tag, false)` (no replicada; el test lo comprueba). Ni `security.lua` ni el resto (`server/`, `client/`, `shared/`) imprime o registra la marca ni el secreto. El backend solo usa `Entity(ent).state.mdp_srv ~= nil` (existencia, `garages.lua:331`). **Sin fugas.**
- **Nota de versión** añadida en `docs/release-notes.md`: las marcas antiguas dejan de ser válidas en el siguiente reinicio (mismo efecto que R3-2).

## Veredicto final de la re-revisión 7
Con `e10f763` (R7-1 y R7-2 cerrados) y la marca HMAC, **la fase 1 queda CERRADA en el plano de seguridad: no quedan hallazgos Críticos, Altos ni Medios abiertos.** Pasan a la fase 2: P1-OWN-M1 (recover), R7-3, AD-1 (valor por defecto) y TR-3 (transacción). Pendiente para el backend: emitir `Security.Log('AUDIT', 'transfer', …)` (TR-5) y en `adopt`/`regularize`/`external`.
