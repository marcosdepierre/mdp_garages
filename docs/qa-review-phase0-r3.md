# mdp_garages: QA, tercera pasada (fase 0, r3)

- Fecha: 16/10/2026, 21:50 (UTC+1). Revisado sobre **HEAD `604b3e8`**, que incluye 5693f27 (Backend r2), 0589ec0 y c5dc8c6 (Integraciones), 6f9379e, 7c34e12 y 574398e (NUI). No he modificado ningún archivo del proyecto salvo este informe.
- `luac -p` (Lua 5.4.7): **OK en todos los .lua**.
- Paridad de locales (script recursivo, incluida la tabla `ui`): **87/87 claves**, mismos `%s/%d`.
- Globales (`luac -l`): `Config, Bridge, Utils, Constants, Locales, _L, Security, MDP`. Ya no quedan `Vehicles/FuelCommon/KeysCommon/BillingCommon` ✔.

## ⚠ Bloqueante: `server/security.lua` no está commiteado

En HEAD, `security.lua` es **idéntico al del commit inicial**. `PlateFromNetId`, `resolvePlate`, `ClaimSpawn`, `OnPlayerDropped`, `despawnOnDropMs` y la caché de rate limit solo existen en el **árbol de trabajo** (sin commitear). Con HEAD:
- `storeVehicle` (garages.lua) llama a `Security.PlateFromNetId` → nil → `resolve_error`: **no se puede guardar ningún coche**.
- `claimSpawns` (vehicles.lua:181) llama a `Security.ClaimSpawn` → error tragado por pcall.
- La política de desconexión de `persistence.lua` (`Security.OnPlayerDropped`) **nunca se llama**, porque el `playerDropped` de HEAD no invoca el hook.

Arreglo: Security tiene que commitear su `server/security.lua`. La revisión que sigue asume esa versión del árbol de trabajo (la he revisado: sintaxis OK).

## A. Puntos abiertos de r2

| Item | Estado | Comentario |
|---|---|---|
| N1 ModelHash | **FIXED** | `Utils.ModelHash`: un número o texto numérico se usa tal cual (se normaliza a signed 32) y si no se hace `joaat`. Se usa en takeOut y storeVehicle. AddVehicle acepta hashes. |
| N2 state 2 | **FIXED** (red de seguridad) | takeOut acepta PARKED_WORLD desde cualquier garaje y borra antes la entidad trackeada. Ver R3-4. |
| N3 owner upsert + revocar llaves | **FIXED** | `ON DUPLICATE KEY UPDATE owner` + `DELETE` de las llaves al cambiar de dueño, también en AddVehicle. |
| N4 Ready + UPDATE condicional | **FIXED** | `MDP.Callback` devuelve `not_ready` hasta que termina onStart; los UPDATE son condicionales al estado leído. Ver R3-5 (si onStart falla no hay reintento). |
| N5 CHARGING → needs_review | **FIXED** | Al arrancar no se resetea: pasa a `needs_review` con log. |
| N6 llaves/fuel/salud | **DIFERIDO (fase 1)** | Hay TODO en garages.lua. |
| N7 sync | **FIXED** | En playerLoaded, en el arranque (jugadores conectados), en AddVehicle y al abrir el garaje (caché de 60 s). Ver R3-2 (rendimiento). |
| N8 needs_review no bloquea | **FIXED** | `channel IN ('internal','invoice')`. |
| N9 migraciones al arrancar | **FIXED** | `UPGRADES` comprueba antes del ALTER (idempotente); el ENUM y `mdp_fine_invoices` también. Matiz R3-6 (UNIQUE de config_id). |
| N10 filtro de tipo | **FIXED** | Los vehículos de un tipo no admitido no se listan. |
| N11 lock sin dueño (Security) | **NOT FIXED** | `Unlock` sigue sin token/dueño (security.lua del árbol de trabajo). |
| N12 textos fine_review (Integraciones) | **FIXED** (c5dc8c6) | `_L('finereview_*')`, claves en en/es. |
| N13 dentro del vehículo + clon | **FIXED / con falso positivo** | Ver R3-1. |
| Parcial 2 reinicio/desconexión | **FIXED solo si se commitea security.lua** | Si no, la política de desconexión no funciona (bloqueante). |
| Parcial 3 sync | **FIXED** | |
| Parcial 10 resolvePlate | **PARCIAL** | `storeVehicle` ya lo usa, pero el `runChecks` con resolvePlate está **sin commitear**. |
| Parcial 15 globales | **FIXED** | Todo cuelga de `MDP.*` / `Bridge.*`. |

## B. Adaptadores (0589ec0, c5dc8c6)

| Hallazgo | Estado | Comentario |
|---|---|---|
| Alta-1 Link/needs_review | **FIXED** | `SafeLink`; `IssueFine` decide con `HasInvoice`. **La decisión de no propagar el boolean es correcta.** En `IssueFine` (billing/init.lua:95-110), `res ~= true` + `hasInvoice == false` hace volver a `internal`. Si el adaptador devolviera `false` cuando la factura **sí se creó** pero falló el enlace, la multa quedaría pagable por `/mdp_payfine` **y** por la factura: doble cobro. Devolver `true` lleva a `needs_review` (bloqueado y revisable). Sugerencia menor (no bloqueante): devolver un tercer estado explícito (`'created_unlinked'`) para que el contrato no dependa de "true aunque falle". |
| Alta-2 okok | **FIXED** | PRIORITY esx_billing > qb-phone > okok. IssueFine elige el primer adaptador con `SupportsFines ~= false`. okok rechaza `meta.fineId` y además exige `Config.OkokTrustServerEvent=true` (default false). |
| Media-1 log de MarkFinePaid | **FIXED** | Error de BD → log en rojo + `needs_review`. OnPaid también registra el fallo. |
| Media-2 Fuel default | **FIXED** | `Fuel.Call` cae a `Bridge.FuelCommon.Get/Set`. Comprobado el orden de los globs: `LegacyFuel.lua` carga antes que `_native.lua`, pero solo usa FuelCommon al llamarse, así que no hay problema. |
| Media-3 matrícula en llaves | **FIXED** | `KeysCommon.Trim/ToPlate/ToEntity` usan `Utils.NormalizePlate/IsValidPlate`. |
| Baja-1 globales | **FIXED** | `Bridge.FuelCommon/KeysCommon/BillingCommon`. |
| Baja-2 notify | **FIXED** | `OX_TYPES` mapea info/primary/warn; se eliminó el fallback muerto. |
| Baja-3 HasKeys qbx | **FIXED** | Matrícula normalizada → entidad (cliente: `GetGamePool('CVehicle')`). |
| Baja-4 billing en cliente | **FIXED** | Se quitó de `client_scripts`. |
| Extra: `bridge/cache.lua` | ✔ | Caché de identificador para usarlo dentro de `playerDropped` (35 s, comprueba si el slot se reutilizó). |

## C. Bugs nuevos (r3)

| # | Severidad | Archivo:línea | Descripción / reproducción | Arreglo |
|---|---|---|---|---|
| R3-0 | **Crítica** | server/security.lua (HEAD) | Ver "Bloqueante": HEAD no tiene `PlateFromNetId`/`ClaimSpawn`/hook de drop. Reproducir: con HEAD, intentar guardar cualquier coche → `resolve_error`. | Commitear el security.lua del árbol de trabajo. |
| R3-1 | **Alta** | server/garages.lua (storeVehicle, `tracked ~= veh` → `not_tracked`) | Falso positivo del anti-clon: solo se pueden guardar coches spawneados por mdp_garages en esta sesión. Un coche recién comprado (spawneado por el concesionario o por `AddVehicle`) o uno sacado con otro script **no se puede guardar nunca**. Reproducir: comprar en qb-vehicleshop, conducir al garaje, guardar → `not_tracked`. | Si `tracked == nil`, aceptar el vehículo cuando OWN + modelo + estado OUT (o un estado "nuevo") y hacer `TrackSpawn` en ese momento. Tratar como clon solo cuando **hay** una entidad trackeada distinta. |
| R3-2 | **Media** | server/garages.lua:48 → vehicles.lua:203 (`claimSpawns` antes de la caché) | Cada apertura de garaje ejecuta, de forma **síncrona** dentro del callback, `SELECT … WHERE owner AND state IN (0,2)` (sin caché). Cada 60 s además: SELECT a la tabla del framework + `SELECT plate IN (…)` + un **upsert de todas las filas aunque nada haya cambiado** (escritura y row locks por apertura). En ESX, `owned_vehicles.owner` no tiene índice por defecto, así que hay full scan. Con 100 jugadores abriendo garajes son muchas consultas y la latencia de la NUI sube. | Ejecutar `claimSpawns` solo al conectarse. Ejecutar la sync en un `CreateThread` sin bloquear la respuesta. Hacer upsert solo de las matrículas nuevas o con dueño distinto (ya tienes `existing`). Documentar `ALTER TABLE owned_vehicles ADD INDEX(owner)` en el README. |
| R3-3 | **Media** | server/vehicles.lua (InsertBatch, upsert) | Cualquier fila del framework con la misma matrícula **roba** el coche a su dueño en mdp (p. ej. un coche creado solo con `AddVehicle` para B, cuya matrícula existe para A en `player_vehicles` por un resto antiguo). No se tiene en cuenta el estado: un coche OUT o IMPOUNDED cambia de dueño con la entidad viva. | Solo transferir cuando `state = GARAGED`; si no, loguear y marcar para revisión. |
| R3-4 | **Media** | server/garages.lua (takeOut desde estado 2) | El estado 2 no cambia si alguien con llave conduce el coche aparcado en la calle. Si el dueño hace takeOut, se **borra la entidad con el otro jugador dentro**. | Antes de borrar, comprobar que nadie va dentro (`GetPedInVehicleSeat(veh,-1) == 0` y sin pasajeros); si hay alguien, devolver `in_use`. |
| R3-5 | **Media** | server/persistence.lua:111-118 | Si `onStart` falla (ALTER sin permisos, falta `install.sql`, error temporal de BD), `MDP.Ready` queda en false **para siempre**: todos los callbacks devuelven `not_ready` y no hay reintento. El mensaje no dice que haya que ejecutar install.sql. No hay deadlock real (sin locks), pero el resultado es un recurso inutilizable. | Reintentar con backoff (por ejemplo 3 intentos a 10 s), comprobar `hasTable('mdp_vehicles')` con un mensaje claro y un comando `mdp_recover` para la consola. |
| R3-6 | **Baja** | server/persistence.lua:37-38 | El upgrade añade `config_id` con DEFAULT '' pero sin `UNIQUE(owner, config_id)`, así que en BD antiguas vuelve la carrera de doble compra (el comentario lo reconoce). | Tras el ADD, `CREATE UNIQUE INDEX` si no existe (si hay filas con '' duplicadas, rellenarlas antes con el id). |
| R3-7 | **Baja** | server/security.lua (árbol de trabajo), playerDropped + persistence `OnPlayerDropped` | `WithLock(plate, 0, applyPolicy…)` devuelve `false,'locked'` en silencio si el lock está tomado (por ejemplo un takeOut en curso), y entonces la política no se aplica. | Loguear el caso `locked` y reintentar con `SetTimeout`. |
| R3-8 | **Baja** | server/vehicles.lua (`FindSourceByIdentifier`) | Recorre `GetPlayers()` en cada AddVehicle. Es aceptable a demanda; no debe usarse en bucles. | Mapa inverso ident→src en `bridge/cache.lua`. |

## D. Veredicto

**La fase 0 (backend + adaptadores) NO se puede cerrar todavía.**

Los adaptadores sí están en condiciones de cierre: todos los hallazgos de la revisión de adaptadores están FIXED y el razonamiento sobre el boolean de `Link` es correcto.

El backend necesita, como mínimo:
1. **R3-0**: commitear `server/security.lua` (Security). Sin eso HEAD no puede guardar coches y la desconexión no funciona.
2. **R3-1**: que el anti-clon no bloquee coches que mdp no ha spawneado (concesionario).
3. Recomendado antes de cerrar: R3-2 (sync sin bloquear y sin upsert redundante), R3-4 y R3-5.

N11 (Security) y N6 (fase 1) pueden quedar como deuda registrada. Con los puntos 1 y 2 corregidos y re-verificados, doy el visto bueno.

---

# R3b: re-verificación tras 4fd38ac (Security) y 76ac9d0

- Fecha: 16/10/2026, 21:55 (UTC+1). HEAD = `76ac9d0` (incluye `4fd38ac`). El árbol de trabajo **no está limpio**, pero solo cambian archivos de `web/` (Frontend); los `.lua` del árbol coinciden con HEAD.
- `luac -p`: **OK en todos los .lua**. No modifiqué archivos del proyecto salvo este anexo.

## Verificación

| Item | Estado | Evidencia |
|---|---|---|
| R3-0 security.lua commiteado | **FIXED** | HEAD contiene `PlateFromNetId` (devuelve plate, err, ent), `resolvePlate` en `runChecks` (borra el `_plate` del cliente y deja la consulta de propiedad para el final), `ClaimSpawn`, hook `OnPlayerDropped`/`OnDroppedVehicleTimeout`. |
| storeVehicle de principio a fin | **FIXED** (salvo R3-1) | `resolvePlate = ResolvePlateFromNetId` → `data._plate` → OWN en el servidor → distancia vehículo ≤5 m → modelo con `Utils.ModelHash` → dentro del vehículo → entidad trackeada → `WithLock` + `UPDATE … state IN (0,2)` + Untrack + Delete. Correcto. |
| claimSpawns | **FIXED** | `vehicles.lua:230-252` usa `Security.ClaimSpawn`, que ahora existe. |
| Política de desconexión conectada | **FIXED** | `fxmanifest`: security.lua (l.47) carga antes que persistence.lua (l.50), así que la implementación de persistence sustituye al hook vacío. `playerDropped` (security.lua) llama a `pcall(Security.OnPlayerDropped, …)`, y `bridge/cache.lua` mantiene el identificador disponible. |
| Parcial 2 (reinicio/desconexión) | **CERRADO** | |
| Parcial 10 (resolvePlate) | **CERRADO** | |
| N11 locks con token | **FIXED** | `Lock` devuelve un token (`src:timer:seq`). `Unlock(plate, token)` solo libera si coincide y registra el rechazo. Un lock caducado se reemplaza con un token nuevo. |
| Llamadas a Lock/Unlock | **OK** | No hay ninguna llamada directa a `Lock`/`Unlock` fuera de security.lua. Todas pasan por `WithLock`, que gestiona el token: garages.lua:97 (takeOut) y :192 (store), persistence.lua:175 (drop) y :186 (timeout), fines.lua:18 (`'fine:'..id`, normalizado a `FINE:<id>`) y vehicles.lua:172 (SyncRemovals). `playerDropped` usa `Unlock(plate, l.token)` ✔. |
| Toma de un lock caducado / carreras | **OK, con matiz** | Si una operación supera `lockTimeoutMs` (10 s), otra puede entrar a la vez. Es seguro porque todas las transiciones son `UPDATE … WHERE state = ?` con `affectedRows == 1`, y el primero, al terminar, no libera el lock del segundo. Las operaciones largas son takeOut (hasta 3 s de espera del spawn + SQL, por debajo de 10 s) y SyncRemovals (una matrícula por lock). Matiz: si un jugador cae a mitad de un takeOut, `playerDropped` libera su lock, la política de drop puede entrar y el takeOut termina después y trackea la entidad con un `src` ya desconectado. No hay duplicado (UPDATE condicional) y `claimSpawns` lo recupera al reconectar. **Baja.** |

## Estado de R3-1..R3-8

| # | Estado | Comentario |
|---|---|---|
| R3-1 anti-clon rechaza coches del concesionario | **NOT FIXED** | garages.lua (storeVehicle): sigue `tracked ~= veh` → `not_tracked` cuando `tracked == nil`. **Alta**, bloqueante. |
| R3-2 rendimiento de la sync al abrir | **NOT FIXED (peor)** | garages.lua:54 sigue llamando a `SyncPlayer` de forma síncrona y `claimSpawns` (vehicles.lua:252) va antes de la caché. Ahora además entra `SyncRemovals` (un SELECT por owner/source más un `SELECT … WHERE UPPER(TRIM(plate)) = ?` por cada matrícula que falte, que no puede usar índice en la tabla del framework). |
| R3-3 upsert sin mirar el estado | **NOT FIXED** | vehicles.lua:99 y :215 hacen `ON DUPLICATE KEY UPDATE owner` sin condición de estado. |
| R3-4 takeOut desde el estado 2 con alguien dentro | **NOT FIXED** | No se comprueba quién va en el vehículo antes de `DeleteEntity(tracked)`. |
| R3-5 Ready sin reintento | **NOT FIXED** | |
| R3-6 UNIQUE config_id en el upgrade | **NOT FIXED** | |
| R3-7 política de drop omitida si el lock está tomado | **NOT FIXED** | persistence.lua:175 ignora el `false,'locked'` que devuelve `WithLock`. |
| R3-8 FindSourceByIdentifier | Sin cambios (Baja) | |

## Bugs nuevos (R3b)

| # | Severidad | Archivo:línea | Descripción / reproducción | Arreglo |
|---|---|---|---|---|
| R3b-1 | **Media** | server/vehicles.lua (SyncRemovals, `DELETE FROM mdp_vehicles`) + install.sql (FK `ON DELETE CASCADE` en mdp_fines/mdp_impound) | Al quitar un coche del framework (venderlo al concesionario o borrarlo), el DELETE en cascada **elimina sus multas impagadas y su registro de depósito**: un jugador puede librarse de las multas vendiendo el coche. Reproducir: multa impagada → borrar la fila de `player_vehicles` → abrir el garaje → la multa desaparece. | No borrar: marcar como retirado (`state = RETIRED` / `source = 'removed'`), o cambiar las FK de multas a `ON DELETE RESTRICT`/sin FK y mantener las multas ligadas al `owner`. |
| R3b-2 | **Baja** | server/vehicles.lua (SyncRemovals) y garages.lua (storeVehicle) | `DeleteEntity` sin comprobar ocupantes: si el coche borrado lo conduce otra persona con llave, o lleva pasajeros al guardar, desaparece con ellos dentro. | Comprobar asientos o hacer `TaskLeaveVehicle` antes de borrar. |
| R3b-3 | **Baja** | server/security.lua (Unlock) | `Unlock` imprime "token no coincide" siempre, también en el caso legítimo de la toma tras caducar. Bajo carga ensucia la consola. | Imprimirlo solo con `debug`, o una vez por clave. |

## Veredicto R3b

**Security queda cerrado.** R3-0, N11 y los parciales 2 y 10 están FIXED, todas las llamadas pasan por `WithLock` con token, y la toma de un lock caducado es segura gracias a los UPDATE condicionales.

**La fase 0 del backend sigue sin poder cerrarse** por un único bloqueante: **R3-1** (no se pueden guardar coches que mdp no haya spawneado, como los del concesionario). Antes de cerrar recomiendo además arreglar **R3b-1** (eliminación de multas por cascada) y **R3-2** (sync síncrona al abrir el garaje, ahora más cara). R3-3..R3-8 se pueden aceptar como deuda de la fase 1 si se documentan. Con R3-1 corregido (y, deseablemente, R3b-1), doy el visto bueno.

---

# R4: pasada final (HEAD `dcc5e00`)

- Fecha: 16/10/2026, 21:58 (UTC+1). HEAD = `dcc5e00` (incluye `4fd38ac` y `76ac9d0`). Sin cambios `.lua` sin commitear: lo pendiente en el árbol es solo `web/` y los informes de QA.
- `luac -p`: **OK en todos los .lua**.
- Paridad de locales: **80/80** (recursivo, `ui` incluido), mismos `%s/%d`.
- No modifiqué archivos del proyecto salvo este anexo.

## Estado R3-0..R3-8, N11 y R3b

| Item | Estado | Evidencia |
|---|---|---|
| R3-0 | **FIXED** | Verificado en R3b; sin cambios desde entonces. |
| N11 | **FIXED** | Tokens; todas las llamadas pasan por `WithLock` (garages ×2, persistence ×2 + `ApplyDisconnectPolicy`, fines, vehicles/SyncRemovals). `playerDropped` usa `l.token`. |
| R3-1 anti-clon / concesionario | **FIXED** | storeVehicle: si `tracked == nil` y la fila está en OUT (OWN + modelo ya comprobados), hace `TrackSpawn` + state bag. Clon solo si **hay otra** entidad trackeada. Para soportarlo: la sync/migración mapea QB `state=0` y ESX `stored=0` → OUT, y `AddVehicle(..., 'out')`. Ver R4-1/R4-2. |
| R3-2 rendimiento | **FIXED** | `SyncPlayer` en `CreateThread` (no bloquea). `claimSpawns` solo con `force`. Upsert por diferencias (solo INSERT de matrículas nuevas y UPDATE de transferencias), sin escrituras si no hay cambios. Queda el `UPPER(TRIM(plate))` de SyncRemovals, que solo se ejecuta para matrículas que faltan (Baja). |
| R3-3 transferencia sin mirar el estado | **FIXED** | Solo se transfiere si el estado es 1/2; si no, se aplaza con log. AddVehicle devuelve `transfer_deferred`. |
| R3-4 takeOut desde el estado 2 | **FIXED** | Devuelve `in_use` si hay alguien en algún asiento y `vehicle_moved` si se movió más de `ParkedMoveTolerance` (5 m). |
| R3-5 Ready | **FIXED** | Reintentos 2/5/10 s, mensaje claro si falta `mdp_vehicles`, comando de consola `mdp_recover`. No hay deadlock (`recovering` como guardia, sin locks). |
| R3-6 UNIQUE config_id | **FIXED** | Rellena `''` → `legacy_<id>` y crea el índice si no existe (consulta `information_schema.statistics`). Idempotente. |
| R3-7 política de drop con el lock tomado | **FIXED** | `ApplyDisconnectPolicy` reintenta cada 2 s, como máximo 5 veces, y lo registra. |
| R3-8 búsqueda inversa | **FIXED** | `Bridge.GetSourceByIdentifier` (mapa en `bridge/cache.lua`). |
| R3b-1 cascada de multas en SyncRemovals | **NOT FIXED** | vehicles.lua:195 sigue haciendo `DELETE` y las FK de mdp_fines/mdp_impound siguen en `ON DELETE CASCADE` (install.sql:82,100). Vender el coche borra sus multas impagadas. |
| R3b-2 DeleteEntity con ocupantes | **PARCIAL** | takeOut lo comprueba (R3-4). storeVehicle (pasajeros) y SyncRemovals no. |
| R3b-3 log de Unlock | **NOT FIXED** | security.lua sigue imprimiendo siempre "token no coincide". |

## Verificaciones pedidas

- **client/main.lua**
  - Si se pierde el foco, se cierra con `UI.Close()` (oculta la NUI y quita el foco). La comprobación va cada 500 ms, tras 1 s de gracia ✔.
  - La pausa sigue bloqueada (199/200) ~250 ms después de cerrar ✔.
  - El hilo solo existe mientras la UI está abierta; no hay `Wait(0)` en reposo ✔.
  - `UI.Open` sin `data.garage.id` no abre y lo registra ✔.
  - `serverCall` normaliza los códigos con `Utils.ErrorCode` ✔.
- **takeOut en estado 3** → `impounded` ✔. La liberación de pago es de la fase 5.
- **SyncRemovals** solo actúa sobre `source='framework'`. AddVehicle inserta `'mdp'` y las filas antiguas (v3 DEFAULT 'mdp') nunca se borran ✔. Si el framework devuelve 0 filas con coches importados, se omite ✔. Si la consulta falla, no se ejecuta ✔.
- **Migraciones** (v1→v3: parked_at, vtype, channel+ENUM, config_id+UNIQUE, mdp_fine_invoices, source): todas comprueban antes de cambiar nada; son idempotentes ✔.
- **Códigos de error** (comprobado con script):
  - `Constants.ErrorCodes` = lista de `architecture.md` §Error codes = claves `ui.err_*` en en/es: **coinciden**.
  - Códigos internos que devuelve Lua y no están en la lista: `internal_error`, `job_denied`, `no_plate`, `payload_not_table`, `resolve_error` y los `invalid_field:*`/`unknown_field:*`. Se normalizan a `rejected` mediante `Utils.ErrorCode`, que es aceptable. Sugerencia (Baja): añadir `job_denied` como código documentado, porque es un motivo útil para el jugador.
- **Web (Frontend)**: en `web/src/types/index.ts` `NUI_ERROR_CODES` **faltan `fine_not_found`, `in_use`, `vehicle_moved`**. `impounded` sí está. Hay que añadirlos también en `i18n.tsx`. Si no, la NUI muestra un código desconocido o el fallback.

## Bugs nuevos (R4)

| # | Severidad | Archivo:línea | Descripción / reproducción | Arreglo |
|---|---|---|---|---|
| R4-1 | **Media** | server/vehicles.lua (MapFrameworkRow: QB `state=0` / ESX `stored=0` → OUT) + persistence onStart | Las filas importadas como OUT **sin entidad en el mundo** (tras reiniciar el servidor, en QB `state=0` suele significar "en el depósito" o "perdido") se quedan en OUT. `takeOut` → `already_out` y `storeVehicle` no tiene entidad: **el coche queda bloqueado** hasta el siguiente reinicio, porque `SyncConnectedPlayers` se ejecuta *después* de convertir los OUT. Reproducir: QB, fila con `state=0`, reiniciar el servidor, el jugador abre el garaje → no puede sacarlo. | Al importar, OUT solo si existe una entidad con esa matrícula (`Bridge.KeysCommon.ToEntity`); si no, GARAGED en DefaultGarage. O hacer que `takeOut` acepte OUT cuando `GetSpawnedEntity` es nil y no existe ninguna entidad con esa matrícula. |
| R4-2 | **Media** | server/persistence.lua (onStart) + garages.lua (R3-1) | En un `restart mdp_garages` (sin reiniciar el servidor), un coche del concesionario en OUT que sigue en el mundo pero **no lleva** el state bag `mdp_plate` no se borra y pasa a GARAGED. El jugador puede sacar otro igual (**duplicado**) y el original ya no se puede guardar (`not_tracked`). | En onStart, buscar también entidades cuya matrícula normalizada sea de una fila OUT (`GetAllVehicles` + `NormalizePlate`) y trackearlas o guardarlas igual que las propias. |
| R4-3 | **Baja** | server/garages.lua (storeVehicle, `TrackSpawn(plate, data.netId, src)`) | `Security.Int` acepta `5.0` (float), pero `TrackSpawn` exige `math.type == 'integer'` y devuelve false sin avisar. | `math.tointeger(data.netId)`. |

## Veredicto final

- **Security: se cierra.** R3-0 y N11 FIXED; tokens correctos en todas las llamadas.
- **Adaptadores: se cierran.** Todo FIXED en R3, sin regresiones.
- **Backend: se cierra con condiciones.** Todos los bloqueantes anteriores (R3-0, R3-1) y R3-2..R3-8 están FIXED. No queda nada Crítico ni Alto. Quedan como **deuda obligatoria antes de la fase 1**, a registrar como tickets:
  - **R3b-1**: no borrar en cascada las multas impagadas en SyncRemovals.
  - **R4-1**: coches importados en OUT sin entidad.
  - **R4-2**: duplicado tras un `restart` con coches de concesionario en el mundo.
  - Bajas: R3b-2, R3b-3, R4-3.
  - Frontend: añadir `fine_not_found`, `in_use` y `vehicle_moved` a `NUI_ERROR_CODES` e i18n.

  Si el equipo prefiere no tener deuda Media al cerrar la fase, R3b-1 y R4-1 son pequeños y se pueden corregir en este mismo ciclo.
- Recordatorio: **nada de esto se ha probado en un servidor FiveM real.** Antes de producción hace falta un smoke test con cada framework (qbx, qb, esx) siguiendo el checklist §4 y §8.

---

# R5: verificación de 19007a4 (HEAD)

- Fecha: 16/10/2026, 22:00 (UTC+1). HEAD = `19007a4` (incluye `2cc9f9e`, NUI). No hay `.lua`/`.sql` sin commitear. No modifiqué archivos del proyecto salvo este anexo.
- `luac -p`: **OK en todos los .lua**. Paridad de locales: **81/81** (recursivo), mismos `%s/%d`.

## Verificación

| Item | Estado | Evidencia / comentario |
|---|---|---|
| R3b-1 multas fuera de la cascada | **FIXED** | install.sql: `mdp_fines` sin FK (las multas van ligadas al `owner`). SyncRemovals hace soft delete (`state = 5 REMOVED`, sin `DELETE`). `mdp_impound` y `mdp_vehicle_keys` conservan su FK, pero como ya no hay DELETE **también se conservan**. |
| Migración v4 | **FIXED** | Detecta la FK en `information_schema.REFERENTIAL_CONSTRAINTS` por `TABLE_NAME`/`REFERENCED_TABLE_NAME`. Esas columnas existen en MySQL 5.7/8 y en MariaDB 10.x, así que no depende del nombre de la FK. Valida el nombre con `^[%w_]+$` antes del `DROP`. Es idempotente: si no hay FK, no hace nada. |
| Restauración si la matrícula reaparece | **FIXED** (con R5-1) | La sync detecta `e.state == REMOVED` y lo devuelve a GARAGED (u OUT si hay entidad), con el nuevo dueño + `onOwnerChanged`. |
| REMOVED oculto y no operable | **FIXED** | `listVehicles` (`state <> 5`), takeOut y storeVehicle → `not_found`. SyncRemovals ignora las filas ya en REMOVED. |
| Multas de vehículos REMOVED | **OK, intencionado** | Siguen pagables (`payFine` filtra por owner/id) y siguen contando para `BlockOnUnpaidFines` (por owner). Es lo correcto: vender el coche no libra de la multa. |
| R4-1/R4-2 adopción al arrancar | **FIXED** | Un solo `Utils.WorldVehiclesByPlate()` (O(n) sobre `GetAllVehicles`, una vez) y un solo SELECT de las filas 0/2. Se adopta por matrícula normalizada **y** `GetEntityModel == Utils.ModelHash(model)`. Un OUT sin entidad pasa a GARAGED (en los dos modos). Las entidades propias huérfanas se borran solo si están vacías. En la sync, la búsqueda de entidades es perezosa (solo si alguna fila nueva está en OUT). |
| Colisiones de matrícula | **Riesgo bajo** | Si dos entidades tienen la misma matrícula, el mapa se queda con la última. El filtro por modelo hace improbable adoptar un coche NPC. Ver R5-3. |
| R3b-2 ocupantes | **FIXED** (con R5-2) | storeVehicle: `Utils.OnlyDriverInside` → `occupied`. SyncRemovals aplaza el borrado si hay alguien dentro. |
| Código `occupied` | **Lua/docs OK, NUI pendiente** | Está en `Constants.ErrorCodes`, en `architecture.md` (§Error codes l.313 y tabla l.333) y en `ui.err_occupied` en/es. **`web/src` no lo tiene**: Frontend debe añadirlo a `NUI_ERROR_CODES` y a `i18n.tsx`. |
| R4-3 netId entero | **FIXED** | `ResolvePlateFromNetId` y `TrackSpawn` usan `math.tointeger`. |
| R3b-3 log de Unlock (Security) | **NOT FIXED** | security.lua:226-227 sigue imprimiendo siempre. Baja. |
| NUI 2cc9f9e | Nota | Añade `in_use`, `vehicle_moved`, `impounded`, `fine_not_found`; falta solo `occupied`. |

## Bugs nuevos (R5)

| # | Severidad | Archivo:línea | Descripción / reproducción | Arreglo |
|---|---|---|---|---|
| R5-1 | **Media** | server/vehicles.lua (AddVehicle, `cur` existe) | `AddVehicle` no tiene en cuenta REMOVED. Si un concesionario vuelve a vender una matrícula que está en REMOVED: con el mismo dueño devuelve `true` y el coche **sigue invisible** (estado 5); con otro dueño, el `UPDATE … state IN (1,2)` falla y devuelve `transfer_deferred` **para siempre**. Reproducir: vender un coche (queda en REMOVED) y llamar `exports.mdp_garages:AddVehicle(owner, plate, model)` → no aparece en el garaje. | Si `cur.state == REMOVED`: `UPDATE … SET state = initialState, owner = ?, garage_id = ?, model = ?, source = 'mdp' WHERE plate = ? AND state = 5` + `onOwnerChanged` si cambia el dueño. |
| R5-2 | **Media** | server/persistence.lua (onStart, `mode == 'garage'`) | Con `OnRestartOutVehicles = 'garage'`, una entidad adoptada en OUT se borra **sin comprobar ocupantes**. En un `restart mdp_garages` con jugadores conduciendo, el coche desaparece con ellos dentro (va contra R3b-2). La rama `'park'` sí lo comprueba. | En `'garage'`, si `not Utils.IsVehicleEmpty(ent)`, dejarlo OUT y trackeado (como en 'park'+ocupado). |
| R5-3 | **Baja** | shared/utils.lua (`WorldVehiclesByPlate`) | Si hay matrículas duplicadas en el mundo, la última entidad gana. Si es la de otro modelo, la buena no se adopta (pasa a GARAGED mientras sigue en el mundo, y puede duplicarse). | Mapa `plate → {ents}` y elegir la que coincide en modelo. |
| R5-4 | **Baja** | server/garages.lua (getVehicles) / mdp_vehicle_keys | Las llaves de vehículos REMOVED se conservan. Al restaurarse con otro dueño se revocan (`onOwnerChanged`), pero con el **mismo** dueño reaparecen las llaves compartidas antiguas. Es aceptable, pero conviene documentarlo. | Documentar, o revocar las llaves al pasar a REMOVED. |

## Veredicto final R5

- **Security: CERRADO** (R3b-3 queda como deuda Baja).
- **Adaptadores: CERRADO.**
- **Backend fase 0: CERRADO con deuda.** Todos los puntos anteriores están FIXED y no queda nada Crítico ni Alto. Deuda registrada para el inicio de la fase 1:
  - **R5-1 (Media)**: AddVehicle sobre una fila REMOVED.
  - **R5-2 (Media)**: borrado con ocupantes en el modo `'garage'` del arranque.
  - Bajas: R5-3, R5-4, R3b-3.

  R5-1 y R5-2 son cambios de pocas líneas. Recomiendo corregirlos antes del primer despliegue en un servidor de pruebas.
- **Frontend:** añadir `occupied` a `NUI_ERROR_CODES` e i18n.
- Sigue pendiente el **smoke test en FiveM real** con qbx, qb y esx (checklist §4 y §8). Ninguna de estas pasadas lo sustituye.

---

# R6: verificación de cierre (HEAD 6eb551d)

- Fecha: 16/10/2026, 22:05 (UTC+1). Incluye Backend `965bfe0`, Security `21eb0e2` y NUI `bdc2eb9`/`6eb551d`. Solo están sin commitear los documentos de QA.
- `luac -p`: **OK en todos los .lua**. Paridad de locales: **81/81**.

| Item | Estado | Evidencia |
|---|---|---|
| R5-1 AddVehicle sobre REMOVED | **FIXED** | vehicles.lua: `UPDATE … WHERE state = 5` con nuevo owner/garage/model/source `'mdp'`. Borra las llaves compartidas, resincroniza al dueño si está conectado y devuelve `true, 'restored'`. Si no restaura nada → `transfer_deferred`. |
| R5-2 nunca borrar un vehículo ocupado | **FIXED** | Arranque en modo `'garage'`: solo si está vacío; si no, aplica la lógica de `'park'`. Las huérfanas solo se borran si están vacías. Política de desconexión `garage`/`impound` con ocupantes (ignorando al jugador que se va) → `keep`. El borrado en `applyPolicy` está protegido. |
| R5-3 adopción única | **FIXED** (ver R6-1) | `WorldVehiclesByPlate` devuelve una lista por matrícula. `UniqueWorldVehicle` adopta solo si hay exactamente una coincidencia en matrícula y modelo. Los duplicados se registran en el log, se marcan en `dupPlates` y no se tocan. |
| R5-4 llaves al restaurar | **FIXED** | `DELETE FROM mdp_vehicle_keys` tanto en la restauración por sync como en AddVehicle. |
| R3b-3 log de Unlock (Security) | **FIXED** | Solo se registra con `Security.Config.debug`; sigue devolviendo `false`. |
| Códigos de error Lua ↔ web | **FIXED** | `Constants.ErrorCodes` coincide 1:1 con `web/src/types` `NUI_ERROR_CODES` (incluye `occupied` y `rejected`). `i18n.tsx` incluye `err_occupied`. |

## Hallazgos nuevos (todos Media/Baja → backlog-phase1.md)
- **R6-1 (Media):** una fila en OUT con matrículas duplicadas en el mundo pasa a GARAGED aunque las entidades sigan existiendo, y el jugador podría sacar otro coche (duplicado).
- **R6-2 (Baja):** en AddVehicle, el borrado de llaves y la resincronización van fuera de `pcall` y del lock.

## Veredicto R6
**Fase 0 de backend, security y adaptadores: CERRADA.** No queda ningún hallazgo Crítico ni Alto abierto. La deuda Media/Baja está en `docs/backlog-phase1.md`. Sigue pendiente el smoke test en FiveM real (qbx/qb/esx) antes de producción.
