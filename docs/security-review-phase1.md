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
