# mdp_garages — Reglas de seguridad obligatorias

Aplican a **todo** el equipo (servidor, cliente, bridges, NUI). Un PR que incumpla una regla no se mergea.

Principio base: **el cliente miente**. Todo lo que llega por `TriggerServerEvent`, `lib.callback` o NUI es entrada hostil. El servidor decide; el cliente solo pide.

Módulo de apoyo: `server/security.lua` (`Security.*`). Depende de `shared/utils.lua` (`Utils.NormalizePlate`, `Utils.IsValidPlate`, `Utils.IsValidGarageId`) para que cliente, NUI y servidor compartan las mismas reglas.

## 1. Validación server-side de cada evento

Todo endpoint que cambia estado se registra con `Security.RegisterSecureCallback(name, opts, handler)` (ox_lib `lib.callback`, sin fallback por eventos). `Security.RegisterSecureEvent` solo para eventos C→S que no cambian estado ni dinero. Prohibido `RegisterNetEvent` directo para lógica de juego.

Cada handler debe comprobar, según aplique:

- **Propiedad**: matrícula + identificador del jugador (`Bridge.GetIdentifier`) contra BD (`requireOwnership = true` → `Security.IsOwner(src, plate[, allowKeys])`: dueño en `mdp_vehicles.owner` o titular en `mdp_vehicle_keys.holder`, ambos con SQL parametrizado; devuelve `true, 'owner'|'key'`. Acciones solo de dueño (vender, transferir, dar llaves) deben llamar `IsOwner(src, plate, false)`). Tabla por defecto `mdp_vehicles` (`Config.Security.ownedTable` si existe). Cuando la acción opera sobre una entidad (p.ej. `storeVehicle`), usar `opts.resolvePlate = function(src, data) return Security.PlateFromNetId(data.netId) end`: la matrícula se resuelve en servidor (`NetworkGetEntityFromNetworkId` → `DoesEntityExist` → `GetVehicleNumberPlateText` → normalizar), se guarda en **`data._plate`** y `requireOwnership` usa esa. Si devuelve `nil, err` se rechaza con `plate_unresolved:<err>`. El handler debe usar `data._plate`, nunca `data.plate`; un `_plate` enviado por el cliente se descarta. Nunca aceptar `owner`/`identifier` enviado por el cliente.
- **Distancia**: jugador ↔ garaje (coords de `Config`) o jugador ↔ vehículo (`GetEntityCoords` en servidor). Distancia máxima en config.
- **Estado del vehículo** (`VehicleState` en `shared/constants.lua`, columna `mdp_vehicles.state`): `GARAGED=1` / `OUT=0` / `PARKED_WORLD=2` / `IMPOUNDED=3`. Solo se saca lo `GARAGED`; solo se guarda lo `OUT`; solo se libera lo `IMPOUNDED`.
- **Regla de arquitectura**: ningún *evento* C→S cambia estado ni dinero; todo lo que cambia estado es un *callback* (ver `docs/architecture.md`).
- **Dinero**: precio calculado en servidor; cobro vía `Bridge.RemoveMoney` y comprobar su retorno **antes** de cambiar estado/spawnear.

### Orden de comprobaciones (`RegisterSecureEvent` / `RegisterSecureCallback`)

1. source válido → 2. rate limit → 3. schema → 4. `resolvePlate` (→ `data._plate`) → 5. job → 6. distancia → 7. propiedad (consulta a BD).

Las comprobaciones baratas van primero; la consulta de propiedad a BD es la última, así una petición lejana o sin permisos nunca llega a la base de datos.

`Security.Config.debug` sigue a `Config.Debug` salvo que se fije `Config.Security.debug` explícitamente.

## 2. Nunca confiar en datos del cliente/NUI

El cliente puede enviar como mucho **identificadores** (`plate`, `garageId`). El servidor busca en `Config`/BD:

| Dato | Fuente válida |
|---|---|
| Precio / tasa de depósito | `Config` / BD |
| Coordenadas de spawn | `Config.Garages[garageId]` |
| Props/mods del vehículo | BD (guardados por el servidor) |
| Id de garaje | Validado contra `Config.Garages` (existe, tipo correcto, job permitido) |
| Modelo | BD |

Al **guardar** props enviados por el cliente: validar que es una tabla, tamaño razonable, y que el modelo coincide con el de la BD (`GetEntityModel` en servidor).

## 3. Rate limiting

Por jugador y por evento (`opts.rateLimit = { max, windowMs }`), por defecto 5 / 2000 ms. Según arquitectura: spawn/store ~1/s (`{max=1, windowMs=1000}`), consultas 5 / 10 s.

Argumentos posicionales: `opts.args = {'plate','garageId'}` los convierte en tabla para el `schema`. Superar el límite → rechazo + log.

## 4. Anti-duplicación y anti spawn múltiple

1. **Lock por matrícula con token**: preferir `Security.WithLock(plate, src, fn, ...)`, que gestiona el token internamente. A bajo nivel, `local token = Security.Lock(plate, src)` devuelve un token único (o `false` si está tomado) y `Security.Unlock(plate, token)` solo libera si el token coincide (si no, registra y devuelve `false`). Un lock caducado (`lockTimeoutMs`, 10 s) se reemplaza con un token nuevo, así que el antiguo dueño ya no puede liberar el lock del nuevo.
2. **Update atómico con condición de estado** y comprobar filas afectadas:
   ```lua
   local affected = MySQL.update.await(
     'UPDATE mdp_vehicles SET state = ? WHERE plate = ? AND owner = ? AND state = ?',
     { VehicleState.OUT, plate, identifier, VehicleState.GARAGED })
   if affected ~= 1 then return end -- otro proceso ganó la carrera
   ```
   Envolver en `Security.WithLock(plate, src, fn, ...)` (libera el lock aunque `fn` falle).
3. **Comprobar entidad existente** antes de spawnear: `Security.GetSpawnedEntity(plate)`; si existe, no crear otra.
4. **Spawn en servidor** con `CreateVehicleServerSetter` cuando sea posible (no spawn en cliente); registrar con `Security.TrackSpawn(plate, netId, src)` (devuelve `false` si plate/netId inválidos) y `Untrack` al guardar/borrar.
4b. **Origen de la entidad:** marcar cada vehículo creado por el servidor con `Security.MarkServerEntity(veh, plate)`. Adoptar solo si `Security.CanAdopt(ent, plate, dbCoords, modelHash)` (entidad del servidor, mismo modelo, vacía, cerca de las coords de BD). **Nunca** usar `mdp_plate` ni otra state bag replicada como prueba: el cliente dueño puede escribirlas. Tampoco `NetworkGetFirstEntityOwner` (devuelve -1 también si el primer dueño se desconectó). Configurar `set mdp_garages_entity_secret "<aleatorio largo>"` en server.cfg y, si es posible, `sv_entityLockdown` y `sv_filterRequestControl`.
5. Si el spawn falla tras el UPDATE, **revertir** el estado (y el cobro) en servidor.
6. Orden: validar → lock → cobrar → UPDATE condicional → spawn → track → unlock.

## 5. Permisos de trabajo (grúa / policía / depósito)

Siempre en servidor vía `Bridge.GetJob(src)` → `{ name, grade, onDuty }`. Usar `opts.job = { names = {'police','mechanic'}, minGrade = 2 }`. Los jobs y grados vienen de `Config`, nunca del cliente. `Security.HasJob` acepta `onDuty` u `onduty` del bridge y **por defecto exige estar de servicio**; `job.requireDuty = false` lo desactiva explícitamente. Garajes de job: validar que el job del jugador coincide con el del garaje.

## 6. SQL

- Siempre **oxmysql parametrizado** con `?`. **Prohibida** la concatenación/`format` de valores en SQL.
- Nombres dinámicos (tabla/columna según framework) solo vía whitelist: `Security.SqlIdent(name)`.
- Usar `MySQL.scalar/single/query/update.await` y comprobar resultados (`nil`, filas afectadas).

## 7. NUI

**Servidor / Lua cliente (callbacks NUI):**
- Validar tipos, longitudes y patrones: matrícula: normalizar (trim, espacios internos colapsados, mayúsculas) y luego `^[A-Z0-9 ]{1,8}$` (longitud `Config.PlateMaxLength`, por defecto 8; regla única en `Utils.IsValidPlate`, nunca hardcodear la longitud); `garage_id` con formato `public|private|impound:<id>` (`Utils.IsValidGarageId`, schema `garage_id = 'garage'`), y además debe existir en la config del servidor, números enteros con `clamp`.
- Rechazar campos desconocidos (schema estricto).
- `Security.V.sanitizeString` para cualquier texto libre (apodos de vehículo): elimina HTML, controles, recorta longitud.
- El callback NUI del cliente solo reenvía al servidor; el servidor revalida todo.

**UI (web/):**
- Prohibido `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write` con datos. Usar `textContent` / `createElement`.
- Escapar al renderizar aunque el dato venga "limpio" del servidor.
- No `eval`, no `new Function`, no URLs construidas con datos sin validar.

## 8. Logging y hooks para ban

- Todo rechazo pasa por `Security.LogReject(src, evento, motivo)` (identificador incluido).
- `Security.OnSuspicious(src, reason, data)` se dispara al superar `flagThreshold` rechazos. Sobrescribir para integrar webhook Discord / anticheat / ban.
- **No banear automáticamente** por rate-limit o distancia (lag, desync). Ban automático solo ante evidencia inequívoca (p.ej. evento solo-servidor disparado por cliente, payload imposible), y siempre registrado.
- Registrar operaciones de dinero y cambios de estado (quién, matrícula, garaje, importe).
- No loguear datos sensibles innecesarios; `debug` incluye payload solo en desarrollo.

## 9. Desconexión (`playerDropped`)

`server/security.lua` aplica esta política:
1. Borra buckets de rate limit y contador de rechazos del `src`. Si `Config.Security.rateCarryMs` > 0 (30000 por defecto), los buckets se guardan por **identificador** y se restauran al reconectar dentro de ese plazo: reconectar no resetea los límites.
2. Libera **solo** los locks cuyo dueño es ese `src` (con su propio token).
3. Mantiene el tracking de vehículos (siguen en el mundo) pero pone su `src = nil`. Con `Config.Security.despawnOnDropMs` (nil por defecto = no hacer nada), tras ese tiempo llama a `Security.OnDroppedVehicleTimeout(plate, netId, identifier)` si el vehículo sigue existiendo y nadie lo reclamó; `server/persistence.lua` decide guardarlo o borrarlo. `Security.ClaimSpawn(plate, src)` reasigna un vehículo al reconectar.
4. Llama al hook `Security.OnPlayerDropped(src, identifier, plates, reason)`.

## 10. Props de vehículo (`Security.SanitizeProps`)

`Security.SanitizeProps(props, dbRow, entity?) -> clean|nil, err, encodedJson`

- Se usa al **guardar** (storeVehicle) las props de `lib.getVehicleProperties` enviadas por el cliente. Guardar `encodedJson` (el JSON ya saneado), nunca el original.
- `dbRow = { plate, model, mileage? }` leído de BD dentro del lock.
- **Modelo**: `props.model` debe coincidir (hash, 32 bits con/sin signo) con `dbRow.model` y, si se pasa `entity`, con `GetEntityModel(entity)`. Si no coincide → rechazo (`model_mismatch` / `entity_model_mismatch`).
- **Matrícula**: se ignora la del cliente y se sustituye por `dbRow.plate` normalizada.
- **Whitelist** (`Security.PropRules`): campos de ox_lib (salud, fuel, colores, mods, extras, neones, ventanas, puertas, ruedas…). Los campos desconocidos **se descartan**; los valores enteros fuera de rango **se descartan**; los decimales se recortan al rango.
- Rangos: `fuelLevel`/`oilLevel` 0-100, `dirtLevel` 0-15, `engineHealth` -4000..1000, `bodyHealth` 0..1000, `tankHealth` -1000..1000, colores 0-255 o `{r,g,b}` 0-255, `mod*` -1..255, `extras` índices 0-20 con 0/1, `neonEnabled` 1-4 booleanos.
- **Kilometraje**: si viene `mileage` menor que el de BD, **se conserva el de BD** (no se rechaza, para no bloquear el guardado por desincronización).
- Límites: profundidad máx. 3, máx. 64 elementos por tabla anidada, JSON final ≤ **16 KB** (`Security.Props.maxBytes`). Superarlos → rechazo (`props_too_deep` / `props_too_large`).
- `Security.ClampHealth('engine'|'body'|'tank', v)` para cualquier salud que se escriba en BD.
- Firma fija: `Security.SanitizeProps(props, dbRow, entity, elapsedSec)`. Con `elapsedSec` (segundos desde la última actualización de km de esa matrícula) el `mileage` pasa por `Security.ClampMileage`.
- **Kilometraje**: `Security.ClampMileage(plate, oldKm, newKm, elapsedSec) -> km, clamped`.
  - Si `newKm` es menor que `oldKm`, no es numérico o es NaN → devuelve `oldKm`.
  - Delta permitido = `max(0, elapsedSec) * Config.MaxSpeedKmh (400) / 3600 + Config.MileageMarginKm (0.5)`, con tope `Config.MaxMileageDeltaKm` (50).
  - Si el delta se supera, devuelve `oldKm + permitido` y `clamped = true` (registrado si `debug`).
- **Snapshots de props de terceros** (el dueño de red cerca de un coche aparcado): solo se aceptan los campos de `Security.PropSnapshotFields` (daños, suciedad, combustible, ventanas, puertas, ruedas). Mods, colores, extras y neones se mantienen de la BD salvo que quien responde sea el dueño o tenga llave.
- **Tokens de petición a clientes**: aleatorios, de un solo uso, con TTL corto, enviados solo al destinatario con `TriggerClientEvent` (**nunca** en una state bag de entidad, que se replica a todos los clientes) y comprobados contra `NetworkGetEntityOwner` al recibir la respuesta.

Revisión de fase 1 con hallazgos para backend: `docs/security-review-phase1.md`.

## 12. Guardar / aparcar solo vehículos propios

**Regla (servidor, dentro del lock de la matrícula, antes de cualquier efecto):** `Security.CanStoreOwnVehicle(src, ent, opts)` debe devolver `true`. Esto exige todo lo siguiente:
1. `Security.IsServerEntity(ent, plate)`: la entidad la creamos nosotros para **esa** matrícula. La marca secreta liga la matrícula; un cambio de matrícula o un clon no la tienen.
2. La matrícula visible (`GetVehicleNumberPlateText`) es igual a la de la marca. Si no → `plate_mismatch`.
3. `Security.GetSpawnedEntity(plate) == ent`: es la entidad trackeada. Si no → `not_tracked`.
4. La fila, releída dentro del lock, tiene `owner == Bridge.GetIdentifier(src)`. Las **llaves no cuentan** (`allowKeys` solo con `Config.AllowSharedKeyStore`, false por defecto). Si no → `not_owner`.
5. Estado de la fila = OUT. Si no → `wrong_state`.
6. Mismo modelo (hash sin signo). Si no → `model_mismatch`.
7. Al guardar, el jugador es el conductor (`allowDriver`). Al aparcar, el vehículo está vacío y el jugador a ≤ `MaxVehicleDistance`. Si no → `too_far` / `not_driver` / `occupied`.

La matrícula sale de la marca o del tracking (`opts.plate` como candidata, que la marca **demuestra**), **nunca** del texto de matrícula que manda el cliente.

**Vectores cubiertos:**

| Vector | Cómo se para |
|---|---|
| Cambio de matrícula en el cliente o con un plate-changer | `plate_mismatch` (la marca liga la matrícula original) |
| Mi matrícula clonada en un coche robado o de NPC (mismo modelo o no) | `not_server_entity` |
| NPC o coche ambiental con la matrícula de una fila de BD | `not_server_entity` |
| `mdp_plate` / `mdp_srv` forjados desde el cliente | `not_server_entity` (el secreto no sale del servidor) |
| netId falso o de otro jugador | `invalid_entity` / `not_owner` |
| Snapshot repetido | Token de un solo uso y comprobación de dueño de red (sección 10) |
| Coche OUT del dueño mientras existe un clon | Solo la entidad trackeada pasa (`not_tracked` para el clon) |
| Guardar mientras otro conduce | `not_driver` / `occupied` |

**Vehículos anteriores a `a8fda43` (sin marca):** se rechazan con un mensaje claro (`vehicle_mismatch` → «Este vehículo no está registrado en el garaje; pide a un admin que lo regularice»). Vía de admin: `/mdp_regularize <plate>` (ACE `command.mdp_regularize`). Solo debe actuar si **no** hay en el mundo ninguna entidad marcada para esa matrícula y la fila está en OUT. Borra únicamente entidades vacías sin marca, nunca cambia el dueño, nunca marca entidades y siempre deja registro.

### Adopción en el primer guardado (concesionarios de terceros)
- **Vía preferida:** el export de servidor `RegisterExternalVehicle(netId, plate)` → `Security.RegisterExternalVehicle(netId, plate, ownerSrc?)`. Hace `MarkServerEntity` + `TrackSpawn` si la entidad existe, la matrícula visible es `plate`, no tiene ninguna marca mdp, no está trackeada para otra matrícula, no hay otra entidad trackeada para `plate`, y la fila existe con el mismo modelo y en estado OUT. No cambia el dueño ni el estado. Solo se puede llamar desde el servidor (los exports no son accesibles desde el cliente) y deja registro con `GetInvokingResource()`.
- `Security.IsTrackedEntity(ent) -> plate|nil` (índice inverso netId → matrícula): cualquier entidad trackeada, para la matrícula que sea, **no** pasa por la adopción. Va por la ruta normal (`CanStoreOwnVehicle`) o por `/mdp_regularize`.
- **Filas importadas del framework:** solo son adoptables si se detectan por primera vez en una sincronización **incremental** de un dueño ya conocido (`mdp_meta.initial_import_done` + `mdp_synced_owners`), en estado OUT, y con la fecha del framework en `[-5 min, +30 min]` cuando existe esa columna (valor NULL → no adoptable). La migración inicial, `mdp_migrate` y la primera sincronización de cada dueño → `managed_at = NOW()`.
- **Heurística de respaldo:** detrás de `Config.AllowFirstStoreAdoption = false` (por defecto). Si se activa, todo esto es obligatorio:
  - Rechazar la entidad si tiene **cualquier** marca mdp (`mdp_srv`/`mdp_plate`) o está trackeada para otra matrícula.
  - `GetEntityPopulationType(ent) == 7` (misión/script, no ambiental).
  - La fila se creó hace ≤ 30 min (`created_at`) y **nunca** ha estado gestionada (columna `managed = 0`; se pone a 1 en la primera adopción o el primer spawn: un solo uso).
  - En BD, `owner == identificador del jugador`; la matrícula visible y el modelo coinciden; no hay ninguna otra entidad viva con esa matrícula; el jugador es el conductor.
  - Al adoptar se conservan las props de BD/stock y del cliente solo se aceptan `Security.PropSnapshotFields`.
  - Rate limit por jugador (p.ej. 1 cada 60 s) y registro de auditoría (`LogReject`/`OnSuspicious` en los rechazos y un print con el identificador en las aceptaciones).
  - Si cualquiera falla, rechazar: es la superficie de un clon.

## 11. Checklist de revisión (PR)

- [ ] Todo evento de red usa `RegisterSecureEvent`/`RegisterSecureCallback` con `schema` estricto.
- [ ] `rateLimit` adecuado definido.
- [ ] Guardar/aparcar: `Security.CanStoreOwnVehicle` dentro del lock y antes de cualquier efecto (incluido auto-impound o liberar huecos); la matrícula sale de la marca, nunca del texto del cliente.
- [ ] Ninguna ruta que guarde o aparque acepta llaves salvo `Config.AllowSharedKeyStore`.
- [ ] Vehículos de terceros: solo vía `RegisterExternalVehicle` (servidor) o la heurística con `AllowFirstStoreAdoption` y todas sus condiciones.
- [ ] Comandos de admin: `restricted = true` (ACE), validación de matrícula, registro, sin reasignar dueño ni marcar entidades arbitrarias.
- [ ] Props del cliente pasadas por `Security.SanitizeProps(props, row, veh)` y guardado el JSON saneado.
- [ ] Salud escrita en BD con `Security.ClampHealth`.
- [ ] Spawn en `pcall` con rollback al estado previo exacto.
- [ ] Acciones sobre entidad: `resolvePlate` + `data._plate` (nunca matrícula del cliente).
- [ ] Propiedad verificada por matrícula + identificador en servidor (llaves solo donde proceda; `IsOwner(..., false)` para acciones de dueño).
- [ ] Matrícula normalizada vía `Utils` (8 máx. por defecto, `Config.PlateMaxLength`) y `garage_id` validado con `Utils.IsValidGarageId` + existencia en config.
- [ ] Jobs: de servicio salvo `requireDuty = false` justificado.
- [ ] Distancia comprobada con coords del servidor/config.
- [ ] Estado (stored/out/impounded) comprobado y cambiado con UPDATE condicional + filas afectadas.
- [ ] Lock por matrícula tomado y liberado en todos los caminos (incluidos errores).
- [ ] Sin spawn duplicado: entidad existente comprobada, netId trackeado.
- [ ] Spawn server-side (`CreateVehicleServerSetter`) o justificado.
- [ ] Precios, coords, props, modelo, garaje: obtenidos de config/BD, no del cliente.
- [ ] Cobro vía bridge y comprobado antes del efecto; reversión si falla después.
- [ ] Jobs/grados verificados en servidor.
- [ ] SQL 100% parametrizado; identificadores dinámicos vía whitelist.
- [ ] NUI: sin `innerHTML`; textos saneados; números clamped.
- [ ] Rechazos logueados; nada de `print` con datos sensibles.
- [ ] Limpieza en `playerDropped` si se guarda estado por jugador.
