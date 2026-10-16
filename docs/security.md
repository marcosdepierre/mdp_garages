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

Revisión de fase 1 con hallazgos para backend: `docs/security-review-phase1.md`.

## 11. Checklist de revisión (PR)

- [ ] Todo evento de red usa `RegisterSecureEvent`/`RegisterSecureCallback` con `schema` estricto.
- [ ] `rateLimit` adecuado definido.
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
