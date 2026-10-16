# mdp_garages: QA, segunda pasada (fase 0, r2)

- Fecha: 16/10/2026, 21:45 (UTC+1). Revisado sobre **HEAD `f4b540f`**, que incluye `e699506` (Backend), `fae64c1` y `58144a6` (Integraciones) y `f4b540f` (Backend: tipos de vehículo, política de desconexión, mapa de parking ESX).
- El árbol de trabajo tiene **cambios sin commitear** en `server/security.lua`, `garages.lua`, `persistence.lua`, `vehicles.lua`, `config.lua`, `fxmanifest.lua` y en la documentación. Solo los cito donde afectan al punto 10 (resolvePlate). No he modificado ningún archivo del proyecto salvo este informe.
- Nota: `fae64c1` es el commit "NUI review (ESC, locales)". Los cambios de Integraciones (`server/fine_review.lua`, `_common.lua`, okokBilling) están en `58144a6`.
- `luac -p` (Lua 5.4.7): **OK en todos los .lua** de HEAD y también en el `server/security.lua` del árbol de trabajo.
- Locales (comprobado con script): en/es tienen **19/19 claves idénticas** y los mismos `%s/%d`. El aviso por clave que falta y el `format` dentro de pcall funcionan (`_L('fine_paid', nil)` ya no falla).
- Matrículas (comprobado con script): `' ab  12 '`→`AB 12` ✔, tabulador colapsado ✔, 9 caracteres rechazados ✔, vacía o solo espacios rechazada ✔.

## A. Verificación de la revisión 1 (qa-review-phase0.md)

| # | Estado | Comentario |
|---|---|---|
| 1 web/dist (Frontend) | **FIXED** | `web/dist/index.html` y `assets/` existen. |
| 2 reinicio/reconexión | **PARCIAL** | `persistence.lua` borra las entidades que quedaron vivas, convierte OUT en bloque, resetea `paid=2` y añade `Config.OnDisconnect`. Pero el estado 2 (PARKED_WORLD) no tiene ningún spawner, así que el modo por defecto `'park'` y `OnDisconnect='keep'` dejan los coches inaccesibles (ver N2). También hay una carrera al arrancar (N4). |
| 3 sync con las tablas del framework | **PARCIAL** | Se sincroniza al cargar el jugador y se añade el export `AddVehicle`. No se propagan cambios de dueño ni bajas (ver N3), y una compra hecha durante la sesión no aparece hasta reconectar. |
| 4 migración type/job/stored | **FIXED** | Respeta type, job, stored y parking (con `ESXParkingMap`). Ver N1: el modelo ESX se guarda mal. |
| 5 multas: doble cobro | **FIXED** | Columna `channel`, payFine solo acepta `internal`, `needs_review` si no se enlaza la factura, y `/mdp_finereview`. |
| 6 override del framework | **FIXED** | `bridge/init.lua:19-36`: lista blanca, `lower()` y comprobación de que el recurso está started; si no, vuelve a auto. |
| 7 locales: aviso y format | **FIXED** | `shared/locale.lua`. |
| 8 tarifa y salud en servidor | **FIXED** | `Config.ImpoundReasons` por `reasonId`. `storeVehicle` y `onDropped` leen `GetVehicleEngineHealth/BodyHealth` en el servidor. syncWear ya solo recibe `mileageDelta`. |
| 9 RATE y UNIQUE de garajes privados | **FIXED** | RATE en tow/enter documentado; `UNIQUE(owner, config_id)`. (`UNIQUE(owner,label)` es opcional y puede molestar.) |
| 10 resolvePlate (Security) | **PARCIAL / sin commitear** | En HEAD no existe. En el árbol de trabajo `runChecks` ya tiene `opts.resolvePlate` → `data._plate` y limpia el `_plate` que mande el cliente. La lógica es correcta. `storeVehicle` (HEAD) no lo usa todavía: lee la matrícula a mano en el handler, que es seguro pero va fuera del pipeline. Pendiente: commitear y migrar `storeVehicle`/`parkWorld` a `resolvePlate`. |
| 11 config documentado | **FIXED** | Formato `descripción · valores · default`; se eliminaron las opciones que no se usaban. |
| 12 innerHTML/textos fijos en la NUI | n/a | Se sustituye por `web/src` (React), que es de Frontend. No hay `innerHTML` en `web/src`. |
| 13 README | **FIXED** | |
| 14 migración por lotes y por framework | **FIXED** | `InsertBatch` de 500 filas; solo el framework detectado. |
| 15 globales | **PARCIAL** | UI pasa a ser local + exports ✔ y `Constants.*` ✔. Aparecen globales nuevas: `Vehicles`, `BillingCommon`, `FuelCommon`, `KeysCommon` (ver B Baja-1). |
| 16 matrículas 1-8 / espacios | **FIXED** | |
| 17 índices / versión de esquema | **FIXED** | `(owner, garage_id, state)`, `mdp_schema_version`, upgrade v2 automático. Ver N9. |
| 18 errores localizados | **FIXED** | `ERROR_KEYS` en `fines.lua`; las claves existen en en/es. |
| 19 sanitizar el motivo | **FIXED** | `IssueFine` limpia y recorta (255/64). |
| 20 documentación | **FIXED** | En general actualizada. |
| 21 ESC duplicado | **FIXED** | El hilo solo recupera el foco colgado (`IsNuiFocused`). |

## B. Verificación de qa-review-adapters-phase0.md

| Hallazgo | Estado | Comentario |
|---|---|---|
| Alta-1 Link falla en silencio → doble cobro interno | **FIXED** (con matiz) | `Link` devuelve boolean y escribe en el log, e `IssueFine` decide con `HasInvoice()` después de `SendBill`: si no hay enlace → `needs_review`, que payFine bloquea. Matiz: `esx_billing.lua:15` y `qb-phone.lua:18` ignoran el retorno de `Link` y devuelven `true`. Hoy funciona solo porque `IssueFine` vuelve a comprobar. Conviene propagar el retorno (`return BillingCommon.Link(...)`). |
| Alta-2 prioridad de okokBilling / evento de servidor sin verificar | **PARCIAL** | `SupportsFines=false` evita que okok se use para multas ✔. Pero okok sigue **primero** en `PRIORITY` (`billing/init.lua:3`): con okok + esx_billing arrancados, `Get()` devuelve okok, se descarta y la multa va a `internal` aunque esx_billing (que sí tiene paid hook) esté disponible. `TriggerEvent('okokBilling:CreateCustomInvoice')` desde el servidor sigue sin verificarse para tasas. Arreglo: en `IssueFine`, resolver el primer adaptador con `SupportsFines ~= false`, o poner okok el último. |
| Media-1 error de BD en MarkFinePaid sin log | **NOT FIXED** | `billing/init.lua` MarkFinePaid: `pcall(...)`; si `ok=false` devuelve false sin imprimir nada. El jugador ya pagó la factura y la multa sigue sin pagar, sin rastro. Arreglo: `print` en rojo + marcar `needs_review`. |
| Media-2 Fuel.Call nil sin default FuelCommon | **NOT FIXED** | `bridge/fuel/init.lua:12-17`: sin adaptador devuelve `fallback` (nil). `_native.lua` solo define helpers y no registra adaptador. Arreglo: si `impl == nil`, usar `FuelCommon.Get/Set`. |
| Media-3 normalización de matrícula en llaves | **NOT FIXED** | `keys/_common.lua:3-7,16-22` solo hace trim: no pasa a mayúsculas ni colapsa espacios. `ToEntity('ab 12')` no encuentra `AB 12`. Arreglo: usar `Utils.NormalizePlate` en `Trim`/`ToPlate`/`ToEntity`. |
| Baja-1 globales FuelCommon/KeysCommon/BillingCommon | **NOT FIXED** | Siguen siendo globales (confirmado con `luac -l`). Arreglo: `Bridge.FuelCommon` etc. |
| Baja-2 mapeo de 'info' en notify + fallback muerto | **PARCIAL** | Los adaptadores mapean `info`→`inform`/`primary` ✔. Pero `notify/init.lua:18,27` llama directamente a `ox_lib:notify`/`lib.notify` con `ntype` **sin mapear** (`'info'` llega crudo a ox_lib), y el adaptador `ox_lib.lua` nunca se usa con `'auto'` (sigue siendo código muerto). Arreglo: en init, resolver siempre el adaptador ox_lib. |
| Baja-3 HasKeys de qbx con matrícula | **PARCIAL** | En servidor convierte matrícula→entidad con `ToEntity` (O(n) sobre `GetAllVehicles` y sin normalizar, ver Media-3). El cliente solo acepta entidad: una matrícula devuelve false sin aviso. |
| Baja-4 adaptadores de billing enviados al cliente | **NOT FIXED** | `fxmanifest.lua:29` `'bridge/billing/*.lua'` sigue en `client_scripts`. Tienen `return` temprano, pero el código del servidor (SQL de qb-phone) se descarga al cliente. Arreglo: sacarlo de `client_scripts`. |

## C. Bugs nuevos

| # | Severidad | Archivo:línea | Descripción / reproducción | Arreglo |
|---|---|---|---|---|
| N1 | **Crítica** | server/vehicles.lua:29-33 (`modelFromProps`) + server/garages.lua:95,147 | En ESX `owned_vehicles.vehicle.model` es un **hash numérico**. Se guarda como `tostring(hash)` (p. ej. `"-344943009"`) y después `joaat("-344943009")` calcula el hash del texto, no el del modelo. Resultado: **ningún coche ESX importado o sincronizado se puede sacar** (spawn_failed tras 3 s) ni guardar (`GetEntityModel ~= joaat(model)` → invalid_request). Reproducir: ESX, comprar un coche, reconectar, takeOut. | Si el modelo es numérico, guardarlo como número (`model_hash INT`) o usar `tonumber(model) or joaat(model)` en un solo helper `Utils.ModelHash`. Hacer lo mismo en `storeVehicle`. |
| N2 | **Alta** | server/persistence.lua (onStart 'park') y onDropped 'keep'; shared/config.lua `OnRestartOutVehicles='park'`, `OnDisconnect='keep'` | Con los valores por defecto los coches pasan a `PARKED_WORLD` (2), pero **no existe el spawner por proximidad**. `takeOut` exige estado 1 y `storeVehicle` necesita la entidad. Tras un reinicio, la entidad se borra y la fila queda en 2 → el coche se pierde. Reproducir: sacar un coche, desconectar (keep), reiniciar el servidor e intentar sacarlo. | Mientras no exista el spawner, usar `'garage'` como default en las dos opciones, o permitir `takeOut` desde el estado 2 si `GetSpawnedEntity(plate)` es nil. |
| N3 | **Alta** | server/vehicles.lua:59-77 (INSERT IGNORE) | La sync solo **añade**. Si el coche se vende o se transfiere en el framework (cambia `owner`/`citizenid`) o se borra, `mdp_vehicles` mantiene al dueño anterior: el antiguo dueño puede seguir sacándolo y el nuevo recibe `plate_exists`/ignorado. Reproducir: transferir la matrícula X de A a B en `player_vehicles` y abrir el garaje con A y con B. | En la sync por jugador, `INSERT … ON DUPLICATE KEY UPDATE owner = VALUES(owner)` cuando la fila del framework existe y `state=1`. Opcional: marcar como retirados los coches que ya no están en la tabla del framework. Añadir un export `TransferVehicle`. |
| N4 | **Media** | server/persistence.lua:51-53 vs server/garages.lua (takeOut) | Los callbacks quedan registrados al cargar el recurso, pero la recuperación se ejecuta dentro de `MySQL.ready`. En un `restart` con jugadores conectados, un `takeOut` que llegue antes de que termine `onStart` pone el coche en OUT y lo spawnea, y luego `UPDATE … WHERE state=0` lo devuelve a GARAGED con la entidad viva → **duplicado**. | Una bandera `Persistence.Ready` que haga rechazar los callbacks con `starting` hasta que termine `onStart`, o excluir del UPDATE las matrículas con `GetSpawnedEntity`. |
| N5 | **Media** | server/fines.lua:24-31 | Si el servidor se cae entre `RemoveMoney` y `paid 2→1`, el reset del arranque (`persistence.lua`: 2→0) deja la multa sin pagar aunque el dinero ya se cobró → el jugador paga dos veces. | Al arrancar, pasar `paid=2` a `needs_review` en vez de a 0 (o registrar el claim con timestamp y revisarlo a mano). |
| N6 | **Media** | server/garages.lua (takeOut, después del spawn) | No se dan llaves (`Bridge.Keys.Call('GiveKeys', …)`) ni se aplican fuel, engine o body. Con qb-vehiclekeys o qbx_vehiclekeys el jugador no puede arrancar el coche. Las props dependen de un cliente de la fase 1. | Llamar a GiveKeys y aplicar salud y fuel en el servidor (`SetVehicleEngineHealth` no es de servidor: enviarlo por state bag). |
| N7 | **Media** | server/vehicles.lua:151-157 | La sync solo se dispara con `esx:playerLoaded`/`QBCore:Server:PlayerLoaded`. Con un `restart mdp_garages` los jugadores ya conectados nunca se sincronizan, y las compras durante la sesión tampoco. | Sincronizar también en `getVehicles` (por owner, con rate limit/caché de 60 s) y, al arrancar, para todos los jugadores conectados. |
| N8 | **Media** | bridge/billing/init.lua (IssueFine) + server/garages.lua `unpaidFinesBlocked` | Las multas en `needs_review` tienen `paid=0` y cuentan para `BlockOnUnpaidFines`. El jugador puede haber pagado la factura y seguir bloqueado hasta que un admin la revise. | Filtrar con `channel IN ('internal','invoice')` en el contador, o avisar al staff. |
| N9 | **Baja** | server/persistence.lua (upgradeSchema) / sql/install.sql | `CREATE TABLE IF NOT EXISTS` no añade a una BD creada con el commit inicial las columnas que llegaron después (`parked_at`, `channel`, `config_id`, `mdp_fine_invoices`). El upgrade v2 solo añade `vtype`, así que `onStart` falla con "Unknown column parked_at" y se salta el reset de multas. | Upgrade v1 idempotente que compruebe esas columnas, o documentar "BD de e5504e6: borrar y reinstalar". |
| N10 | **Baja** | server/garages.lua (listVehicles, filtro de tipo) | El comentario dice que se omiten los vehículos de un tipo no permitido, pero el código solo omite el campo `vtype`; el vehículo aparece igual en la lista y `takeOut` devuelve `wrong_vehicle_type`. | Hacer `goto continue` o no añadirlo a `out`. |
| N11 | **Baja** | server/security.lua (WithLock + lockTimeoutMs 10 s) | Si el handler tarda más de 10 s, otro caller toma el lock y el primero, al terminar, borra el lock del segundo (Unlock no comprueba el dueño). | Token por lock y desbloquear solo si coincide. |
| N12 | **Baja** | server/fine_review.lua:127,133,135 | Textos fijos en español ("Uso:", "Multa #%d …"), fuera de los locales. | Pasarlos a claves `_L`. |
| N13 | **Baja** | server/garages.lua (storeVehicle) | No comprueba que el jugador esté en el vehículo ni que la entidad sea la trackeada (`GetSpawnedEntity`). Un coche clonado con la misma matrícula y modelo (mod menu) se puede guardar; el original sigue vivo. | Exigir `GetSpawnedEntity(plate) == veh` o, si no lo es, borrar ambos. |

## D. server/security.lua (revisión completa, HEAD + árbol de trabajo)

- ✔ SQL parametrizado, whitelist de identificadores, `IsOwner` incluye a quien tiene llave, rate limit con ventana deslizante, `packArgs` rechaza argumentos de más, limpieza en `playerDropped`, `requireDuty` acepta `onDuty`/`onduty`, la callback devuelve `(false, motivo)`.
- ✔ (sin commitear) `resolvePlate` + `_plate` del lado del servidor y borrado del `_plate` que envía el cliente.
- ⚠ N11 (lock sin dueño). `Security.Config.debug` no sigue `Config.Debug` (Baja). `runChecks` consulta la BD (OWN) antes de comprobar la distancia, que es más barata (Baja, rendimiento). El comentario de `playerDropped` remite a `server/main.lua`, pero la política está en `persistence.lua` (Baja, documentación).
- Rendimiento: `isSpawnFree` y `KeysCommon.ToEntity` recorren `GetAllVehicles()`; es aceptable a demanda, pero no debe ir en bucles. El único `Wait(0)` es con la NUI abierta ✔.
