# Backlog fase 1 (deuda QA no bloqueante)

## Desde QA R6 (16/10/2026)

| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| R6-1 | Media | server/persistence.lua:129-132; server/vehicles.lua:99 | Si una fila en OUT tiene ≥2 entidades en el mundo con la misma matrícula y modelo, no se adopta ninguna (correcto), pero la fila cae en la rama "sin entidad" y pasa a GARAGED mientras las entidades siguen en el mundo. El dueño puede sacarlo del garaje y queda un coche más (duplicado). | Si `matches > 1`, dejar la fila en OUT (o marcarla para revisión) en lugar de pasarla a GARAGED. En vehicles.lua, tratar igual `matches > 0`. |
| R6-2 | Baja | server/vehicles.lua (AddVehicle, rama REMOVED) | `DELETE FROM mdp_vehicle_keys` va fuera de `pcall`. Si la base de datos falla, el error se propaga al export que llama, cuando la restauración ya está hecha. | Envolverlo en `pcall` y registrar el error en el log, o hacerlo en el mismo UPDATE/transacción. |
| NUI-R4-1 | Baja | web/dist (bundle) | El JS pasa a 558 KB / 166 KB gzip (antes 357/111) por react-aria Table/GridList, exigido por la decisión N10. Vite avisa de un chunk >500 KB. Es local en CEF y no bloquea. | Valorar `manualChunks` (vendor react-aria) o `build.chunkSizeWarningLimit`; medir el tiempo del primer open en el cliente. |
| NUI-R4-2 | Baja | web/src/components/base/{avatar,checkbox,dropdown,radio-buttons,toggle,tooltip} | Componentes UUI que no se usan, vueltos a añadir en bdc2eb9 (no entran en el bundle por tree-shaking, pero ensucian el código). | Borrarlos si no se usan en fase 1. |
| NUI-R4-3 | Baja | web/src/views/DetailView.tsx:67-75 | Bloque de stats (label + % + barra) maquetado con div/span; la barra sí es UUI. Es layout, no un componente propio. | Aceptable; si el lead lo exige, pasarlo a una fila de Table o usar `ProgressBar labelPosition="top-floating"` de UUI. |
| NUI-R4-4 | Baja | — | N11 (color-scheme solo en el panel) no se ha podido verificar en el cliente FiveM. | Comprobarlo en el juego: el mundo tiene que verse alrededor del panel. |
| NUI-R5-1 | Baja | web/tests/n16-row-select.mjs | El e2e solo cubre la selección de filas; ESC, Take out y el hint de deshabilitado se probaron a mano (QA R5). Tampoco se ejecuta en CI. | Añadir esos casos y un job de CI (`vite` + `npm run test:e2e`). |
| NUI-R5-2 | Baja | web/src/views/VehicleTable.tsx:17-28 | Con `selectionBehavior="replace"`, las flechas mueven la selección y abren el detalle de cada fila al navegar (comportamiento aceptable, pero cada paso re-renderiza el detalle). | Confirmar con diseño; si molesta, `selectionBehavior="toggle"` + Enter. |

## Backend — revisión de seguridad fase 1 (16/10/2026)

| # | Estado | Nota |
|---|---|---|
| L3 | Aceptado | `saveEntityCoords` en `onResourceStop` sin lock: el UPDATE es condicional (`state = OUT`) y ahora valida coords (L4). Se deja así. |
| Streamer props | Abierto | Las props no se leen en servidor: al despawnear solo se guardan coords/heading/salud; mods cambiados en un coche aparcado se pierden hasta el siguiente store/park. |
| Odómetro | Abierto | km acumulados solo en el cliente conductor; si cambia de conductor sin store/park se pierde el tramo. |
| Km primer guardado | Aceptado (Senior) | Coches añadidos por otros scripts (p.ej. concesionarios) no tienen hora registrada en su primer guardado: solo aplica el margen de 0,5 km (mitigado en parte por el fallback a `parked_at`/`updated_at` de la BD, N5). |
| Llaves compartidas (fase 3) | Pendiente | Hoy guardar/aparcar es solo del dueño; las llaves compartidas solo sirven para conducir. `Config.AllowSharedKeyStore` (false) reservado para decidir en fase 3. |
| TR-3 (fase 2) | Pendiente | DELETE de llaves y UPDATE de dueño en una transacción (hoy el error se registra en el log). |
| TR-4 (fase 2) | Parcial | Varias filas del framework para una matrícula: hoy se omite el chequeo y no se transfiere (log). Falta una herramienta de admin para resolverlo. |
| TR-5 (fase 2) | Parcial | Guard old == new hecho. Falta log AUDIT de cada transferencia (dueño antiguo, nuevo, origen) con un helper de Security. |
| R2-M2 (fase 2) | Pendiente | Diferido por Senior a fase 2 (ver docs/qa-review-phase1-backend.md). |
| R2-L1 (Baja) | Pendiente | `FrameworkOwner`: una matrícula del framework con doble espacio interno no coincide con la normalizada (búsqueda indexada exacta). |
| R3-L (índice QB) | Pendiente | Comprobar/recomendar índice en `player_vehicles.plate` (QB/Qbox) para la búsqueda indexada; ESX `owned_vehicles.plate` es PK. |
| P1R3-L1 (Baja) | Pendiente | Coche OUT sin marca y vacío borrado al arrancar → GARAGED con props de la BD (se pierde tuning de calle). |
| P1R3-L2 (Baja) | Aceptado | Dueño de red puede escribir `mdp_srv` con strict mode desactivado (DoS de su propio coche); mitigado con `sv_stateBagStrictMode`. |
| P1-OWN-M1 / R3-M1 hueco | Pendiente | Coche sin marca (o clones sin ninguno marcado) que queda OUT tras reiniciar: el dueño no puede guardarlo sin debilitar las reglas (`vehicle_mismatch`) fuera de la ventana de adopción; salida: `/mdp_regularize` o reinicio con el coche vacío. Falta una re-adopción segura diseñada con Security. |

## Desde QA fase 1 backend (16/10/2026, HEAD ac77923) — ver docs/qa-review-phase1-backend.md

| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| P1-M1 | Media | server/streamer.lua `despawnParked` | No vuelve a comprobar `state=2` ni la distancia dentro del lock. Si en la espera del snapshot (2 s) alguien sube y baja (OUT), se borra el coche OUT; si un jugador vuelve, el coche parpadea. | Releer `state=2` y `nearest > despawnR` dentro del lock antes de borrar. |
| P1-M2 | Media | server/streamer.lua (evento `propsSnapshot`) | Cualquier dueño de red (no el propietario) puede reescribir el tuning o los colores persistentes de coches ajenos con props válidas por whitelist. | Del snapshot de terceros aceptar solo daño/suciedad, o hacer merge conservando `mod*`/colores de BD. |
| P1-M3 | Media | server/streamer.lua:80 | `WorldVehiclesByPlate()` (recorrido de `GetAllVehicles`) en cada spawn: hasta 5 por tick. | Un mapa por tick, o adoptar por `mdp_plate`. |
| P1-M4 | Media | server/streamer.lua:94, docs/architecture.md:375 | Coche aparcado cerrado (2): con qb-vehiclekeys tras reinicio/reconexión, o con ESX sin llaves, el propietario no puede abrirlo. | `GiveKeys` al propietario conectado en el spawn del streamer, o no cerrar sin adaptador de llaves. |
| P1-L1 | Baja | server/vehicles.lua:~107 | R6-1 parcial: en la sync, un OUT con duplicados en el mundo pasa a GARAGED. | `matches > 0` → mantener OUT. |
| P1-L2 | Baja | server/props.lua `mileageStamp` | La marca de km es solo de memoria: tras un restart, el límite es de 0,5 km en el primer store de los coches adoptados. | Marcar en la adopción de `onStart` o persistir. |
| P1-L3 | Baja | server/security.lua PROP_RULES | Se descartan `windowsBroken`/`doorsBroken`/`tyreBurst` (ESX/QB). | Alias → `windows`/`doors`/`tyres`. |
| P1-L4 | Baja | server/garages.lua:308-316 | Límites de aparcamiento contados fuera del lock (+1 con carrera). | Volver a contar dentro del lock. |
| P1-L5 | Baja | server/props.lua `doSpawn` | Props importadas del framework sin sanear en el servidor. | `SanitizeProps` en import/migrate. |

R6-2: cerrado (pcall en AddVehicle). R6-1: cerrado en persistence.lua, parcial en vehicles.lua (P1-L1).

## Estado tras QA fase 1 R2 (16/10/2026, HEAD 078ac23)
- **Cerrados:** P1-M1 (queda el residual P1R2-L3), P1-M2, P1-L1, P1-L2.
- **Abiertos:** P1-M3, P1-M4 (aceptado y documentado), P1-L3, P1-L4, P1-L5 (parcial: la salud importada ya se limita, las props no se sanean).

| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| P1R2-L1 | Baja | server/security.lua `PropSnapshotFields` | Un extraño que es dueño de red puede persistir `windows/doors/tyres/dirt` rotos en un coche ajeno (salud y fuel los pisan las columnas). | Para snapshots parciales aceptar solo valores que empeoren respecto a la BD y limitar la frecuencia, o aceptar solo daño de un snapshot del propietario. |
| P1R2-L2 | Baja | server/vehicles.lua:256-264 (AddVehicle) | `json.encode(props)` y `SanitizeProps` sin pcall: NaN/inf → el export lanza un error en vez de devolver `invalid_props`. | pcall en los dos. |
| P1R2-L3 | Baja | server/streamer.lua `despawnParked` | No recalcula `nearest > despawnR` dentro del lock: parpadeo si un jugador vuelve durante el snapshot de 2 s. | Recalcular la distancia antes de borrar. |
| P1R2-L4 | Baja | server/streamer.lua `mergeSnapshot` | Con `props` NULL en la BD, la base `{}` no tiene `model` → `SanitizeProps` lo rechaza y se pierde el desgaste. | Base `{ model = row.model }`. |

## QA fase 1 — Integraciones (16/10/2026, commits 4bf7b64 + ac77923)
| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| P1I-M1 | Media | bridge/vehicle/props.lua:136-149 | El NACK determinista se acepta sin repetir las comprobaciones en el servidor (lo contrario de lo que dice integrations.md); un dueño de red ajeno puede anular la aplicación de props. | Validar en el servidor el modelo y que el payload se decodifica antes de aceptar el NACK. |
| P1I-M2 | Media | bridge/vehicle/framework_sync.lua:98-101 | `OnRelease` sin llamadores: `pound` de ESX no se limpia al liberar. | Hook en la liberación del incautado. |
| P1I-M3 | Media | server/vehicles.lua:82-85 | Al cambiar de dueño no se revocan las llaves del recurso externo. | `Bridge.Keys.RemoveKeys` al antiguo dueño si está online. |
| P1I-M4 | Media | server/streamer.lua | P1-M4 sigue abierto: Integraciones no da llaves en el spawn del streamer. | Ver P1-M4. |
| P1I-L1 | Baja | server/garages.lua:259-261 | `OnStore` tras `DeleteEntity`: con qbx `RemoveKeys` devuelve false (inocuo). | Llamarlo antes de borrar la entidad. |
| P1I-L2 | Baja | bridge/vehicle/props.lua (cliente) | Fallo transitorio: `propsApplied(false)` llega solo tras ~10 s. | Documentar o emitir un aviso antes. |

## Desde QA fase 1 R3 (16/10/2026, HEAD fecc05a)
- **Cerrado:** P1R2-L4 (N2b, `model` en `mergeSnapshot`).
- **Siguen abiertos:** P1-M3, P1-M4/P1I-M4, P1I-M1..M3.
- **Bloqueante, no backlog:** P1R3-H1 (Alta), en docs/qa-review-phase1-backend.md §R3.

| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| P1R3-L1 | Baja | server/persistence.lua (adopción al arrancar, rama rechazado y vacío) | Un coche en OUT sin marca y vacío se borra y pasa a GARAGED con las props de la BD: se pierde el tuning no guardado (coches de concesionario). | Snapshot antes de borrar, o pasarlo a PARKED_WORLD en el sitio. |
| P1R3-L2 | Baja | server/security.lua `MarkServerEntity`/`IsServerEntity` | Sin `sv_stateBagStrictMode`, el dueño de red puede sobrescribir `mdp_srv` y romper la adopción de su propio coche (DoS sobre sí mismo). | Confiar primero en `serverEnts`; documentar el modo estricto como requisito. |
| P1F-M1 | Media | web/src/types/index.ts (`NUI_ERROR_CODES`) | Falta `invalid_props` (sí está en `Constants.ErrorCodes`, architecture.md, i18n y locales). `normalizeError` lo convierte en `rejected` → un store con props inválidas muestra "Solicitud rechazada" en lugar de `err_invalid_props` (verificado con un toast real). | Añadir `'invalid_props'` a `NUI_ERROR_CODES` y un test que compare las 5 listas. |
| P1F-M2 | Media | client/zones.lua `guarded` (fecc05a) | El safety timeout de 15 s libera `busy` aunque la petición siga en curso (el `lib.callback.await` de ox_lib espera hasta `ox:callbackTimeout` = 300 s). `/mdp_park` (hilo de comando) puede mandar un segundo `parkWorld`/`storeVehicle` mientras el primero está pendiente; el resultado tardío se descarta sin toast, así que el jugador ve "timeout" aunque la operación haya salido bien. El servidor lo protege (WithLock + estado + RATE). | Pasar timeout a la llamada (`lib.callback.await` con `ox:callbackTimeout` bajo o un promise propio con `SetTimeout` que resuelva `timeout`) y no liberar `busy` hasta que la promesa se resuelva; o al llegar tarde, mostrar el resultado real con el mismo id. |
| P1F-M3 | Media | client/zones.lua `point:nearby` → `storeCurrent`/`openGarage` | `storeCurrent` hace `lib.callback.await` dentro de `nearby`, que ox_lib llama desde el hilo único de points: mientras espera (normalmente ~100 ms, hasta 300 s en el peor caso) se congelan todos los points (onExit/textUI, abrir garaje). | Envolver la acción en `CreateThread(function() storeCurrent(id) end)` (guarded ya serializa). |
| P1F-M4 | Media (decisión del lead) | web/package.json `sonner` 2.0.8, web/src/toasts.tsx | Librería fuera de UUI para los toasts (Notifications es PRO). La pide el Designer (§7/§9.3) y es dependencia del propio repo untitleduico/react (package.json upstream: `sonner ^2.0.8`), pero la regla dura del lead no la recoge como excepción. El contenido del toast es un div maquetado con FeaturedIcon + Button UUI. | El lead lo aprueba por escrito (como los mdp patches) y se anota en UNTITLEDUI_PATCHES.md. |
| P1F-L1 | Baja | client/zones.lua `storeCurrent` | El cliente solo comprueba que eres el conductor, no que vas solo; con pasajeros se manda la petición y el servidor responde `occupied` (toast traducido). F1-G pide "conductor y solo". | Comprobar los asientos (`IsVehicleSeatFree` / `GetVehicleNumberOfPassengers`) antes de enviar y avisar con `err_occupied` sin hacer la llamada. |
| P1F-L2 | Baja | client/props.lua (odómetro) | Bucle permanente fuera de las zonas (Wait 1000/1500). No es Wait(0), pero va contra "sin bucle activo fuera de zonas". | `lib.onCache('vehicle')`/`cache.seat` para arrancar el hilo solo al conducir. Medir resmon en el cliente (no se ha podido medir). |
| P1F-L3 | Baja | web/src/toasts.tsx, DetailView | §9.2/9.4: falta "Reintentar" dentro del toast de error y el retardo de 1 s para `rate_limited`. | Añadir action al toast para los códigos de RETRYABLE; deshabilitar Retry 1 s si `rate_limited`. |
| P1F-L4 | Baja | web/src/format.ts `fmtMoney` | En inglés sale `2,500 $` (sufijo fijo). | `Intl.NumberFormat(lang, {style:'currency', currency:'USD', maximumFractionDigits:0})`. |
| P1F-L5 | Baja | web/src/views/VehicleTable.tsx:44-45 | Las barras de la lista usan `clampPct(v.engine,10)` y el detalle `healthPct` (mismo resultado hoy, pero son dos caminos). | Usar `healthPct` en los dos sitios. |

## Desde QA fase 1 R4 (16/10/2026, HEAD 29d09a5)
- **Cerrado:** P1R3-H1 (Alta).

| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| P1R4-L1 | Baja | shared/utils.lua:174-178 `Utils.SameModel` | Los floats no enteros se convierten en 0 en los dos lados → `SameModel(1.5, 2.5) == true`. Un nombre de modelo como string devuelve false (se espera un hash). | Si `math.tointeger` da nil → return false; documentar que se esperan hashes o aplicar `Utils.ModelHash` dentro. |

## Desde QA frontend fase 1 R2 (16/10/2026, a2700ae)
- **Cerrado:** P1F-M1. **Abierto (parcial):** P1F-M2 (ver P1F-R2-M1/L1). P1F-M3 resuelto de hecho por el `lib.callback` asíncrono, falta confirmarlo en un cliente real.

| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| P1F-R2-M1 | Media | client/zones.lua:52-53 | El éxito tardío hace toast sin comprobar el token: si ya hay otra petición en curso (después de 20 s), reemplaza su toast loading (mismo id) con el éxito de la anterior. | `elseif t.kind == 'success' and attempt == token`, o un id de toast por intento. |
| P1F-R2-L1 | Baja | client/zones.lua:37 | El backstop de 20 s libera `busy` con la petición de ox_lib aún viva (hasta 300 s) → se puede reenviar (lo cubre el servidor). | Exigir `ox:callbackTimeout` ≤ 20000 o no liberar hasta la respuesta real. |
| P1F-R2-L2 | Baja | client/zones.lua:53 | El error tardío después del timeout de 15 s se descarta: el jugador solo ve "timeout". | Mostrar el error tardío si `attempt == token`. |
| P1F-R2-L3 | Baja | web/UNTITLEDUI_PATCHES.md:172 | Viñeta "Reason" en inglés que repite la sección sonner en español. El commit se describió como frontend pero toca Lua. | Juntar en un solo texto y describir el alcance real. |
| P1F-R2-L4 | Baja | web/src/types/index.ts:60-64 | Falta el test que compara las 5 listas de códigos de error. | Test o script de CI. |

## Desde QA frontend fase 1 R3 (16/10/2026, 169cb30)
- **Cerrados:** P1F-M2, P1F-R2-M1, P1F-R2-L2, P1F-R2-L3, P1F-R2-L4 (con la reserva R3-L1).
- **Sigue abierto:** P1F-R2-L1 (`ox:callbackTimeout` no documentado fuera de un comentario de código).

| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| P1F-R3-M1 | Media | client/zones.lua:49-50 | El callback asíncrono ignora el 2.º valor: los rechazos de Security (`false, 'rate_limited'/'too_far'/'invalid_request'`) salen como "Server error"; `res.error` no se normaliza con `Utils.ErrorCode` (`plate_unresolved:nil` → "Request rejected"). | Normalizar igual que `serverCall` en client/main.lua:53-60. |
| P1F-R3-L1 | Baja | web/tests/error-codes.e2e.mjs:17-19 | Si falta `err_<c>` en en.lua solo hay WARN, y es.lua no se comprueba. | Hacer que falle si falta la clave en en.lua o es.lua. |

## Desde QA Propiedad (16/10/2026, b17d813/f01f58d/53c2c56/7de0844/7ad284c)

| # | Severidad | Archivo:línea (7ad284c) | Descripción | Arreglo |
|---|---|---|---|---|
| P1-OWN-M1 | Media | server/persistence.lua:160 + garages.lua:313 | Un coche en OUT sin marca y ocupado tras reiniciar (`keepOut`) no se puede guardar ni aparcar; el jugador no tiene forma de re-adoptarlo. Solo sale con `/mdp_regularize` de un admin (con el coche vacío) o con otro reinicio. | Re-adopción para el dueño conductor (mismo modelo, matrícula única en el mundo, auditada) o marcarlo en el reinicio como "adoptable por el dueño". |
| P1-OWN-M2 **CERRADO (677f577)** | Media | server/garages.lua:482-501 | `/mdp_regularize` pasa a GARAGED desde **cualquier** estado distinto de 5: libera incautados (3) sin pagar multas ni cerrar `mdp_impound`, y revive retirados (4). Harness: FAIL en los dos casos. | Permitir solo los estados 0/2 (`WHERE state IN (0,2)`) y responder un error claro para los demás. |
| P1-OWN-M3 | Media | server/garages.lua:579-592 | `RegisterExternalVehicle` no recibe `src` ni comprueba el dueño: un recurso de confianza que reenvíe datos del cliente permite registrar la fila nueva de otro jugador sobre una entidad del atacante. | Añadir el parámetro `src` y exigir `owner == GetIdentifier(src)` y que `src` esté cerca o sea el conductor; documentar que no se reenvíen datos del cliente. |
| P1-OWN-M4 | Media | server/garages.lua:280 | Population type 7 incluye los coches creados por scripts de cliente: un tramposo puede fabricar su propio coche (OUT, nuevo y sin gestionar). Solo afecta a sus coches. | Exigir RegisterExternalVehicle o `NetworkGetEntityOwner`/`GetEntityOrphanMode`/el creador del lado del servidor; probar `SetEntityAsMissionEntity` en el motor. |
| P1-OWN-M5 **CERRADO (677f577)** (NULL/futura con columna de fecha; sin columna sigue siendo adoptable, pendiente de Security) | Media | server/vehicles.lua:131,163 | Importación adoptable con `fwCreatedTs == nil` (sin columna o con fecha NULL/no parseable) o con fecha futura → la ventana del framework no se aplica. Probablemente ningún esquema estándar (ESX/QB/Qbox) tiene columna de fecha. **Pendiente de Security.** | Si la columna existe y la fecha es NULL o futura → no adoptable; quitar `date` de `DATE_COLS` o hacerlo configurable. |
| P1-OWN-L1 **CERRADO (677f577)** | Baja | server/garages.lua:362,437 | Conductor único y vehículo vacío se comprueban antes del lock; entre medias hay `await`, así que alguien puede subir y se borra o aparca con gente dentro. | Repetir `OnlyDriverInside`/`IsVehicleEmpty` dentro del lock. |
| P1-OWN-L2 | Baja | shared/config.lua (AllowSharedKeyStore), garages.lua:334,442 | Un flag de configuración vuelve a aceptar las llaves, en contra del requisito "las llaves nunca cuentan". | Quitarlo hasta la fase 3 o ignorarlo en store/park. |
| P1-OWN-L3 **PARCIAL (677f577)**: ahora se loguea, pero sigue devolviendo `vehicle_mismatch` | Baja | server/garages.lua:338 | Si `CanStoreOwnVehicle` lanza un error, se muestra como `vehicle_mismatch` en vez de `server_error`, y no queda en el log. | Loguear y devolver `server_error`. |
| P1-OWN-L4 | Baja | server/garages.lua:363-371 | La adopción marca, trackea y pone `managed_at` antes de `wrong_vehicle_type`/`invalid_props`. Si el guardado falla, el coche queda adoptado (no es un bypass, pero el estado queda a medias). | Adoptar después de las validaciones, o deshacerlo si falla. |
| P1-OWN-L5 | Baja | server/security.lua:162-175 | El rate limit de adopción va por `src`; se recupera por identificador solo durante 30 s (`rateCarryMs`). Un relog lo resetea. | Clave por identificador para `adopt:firstStore`, o carry de 10 min. |
| P1-OWN-L6 | Baja | server/persistence.lua:86 | Si el upgrade se cae entre el ALTER y el backfill de `managed_at`, el backfill no se repite. | Backfill guiado por una marca en `mdp_meta` y no por la existencia de la columna. |
| P1-OWN-L7 | Baja | server/vehicles.lua:365 | `syncPlayer` consulta `mdp_meta`/`mdp_synced_owners` fuera de pcall y sin esperar a `MDP.Ready` (un jugador que entra durante el upgrade da error). | Esperar a `MDP.Ready` o meterlo en pcall. |
| P1-OWN-L8 | Baja | sql/install.sql vs persistence.lua:95-105 | install.sql crea `mdp_synced_owners`/`mdp_meta` sin sembrar. Ejecutarlo sobre una BD existente impide el seed del upgrade (falla de forma segura: nada adoptable). | Seed por marca en `mdp_meta` (`owners_seeded`), no por la existencia de la tabla. |
| P1-OWN-L9 | Baja | server/garages.lua:493 | `/mdp_regularize` borra entidades y luego aborta si encuentra una ocupada (a medias). Borra cualquier entidad sin marca con esa matrícula, sea cual sea el modelo. | Primero escanear y luego borrar; filtrar por `SameModel`. |

## Desde QA Propiedad R2 (16/10/2026, 8a4e3cf + 677f577)
Cerrados: P1-OWN-H1, P1-OWN-H2 (Altas, ver review), M2, M5 y L1. L3 parcial. Siguen abiertos: M1, M3, M4, L2, L4-L9.

| # | Severidad | Archivo:línea (677f577) | Descripción | Arreglo |
|---|---|---|---|---|
| P1-OWN-R2-M1 **CERRADO (2b60c36)** (ver R3-M1) | Media | server/garages.lua:88-96, 130, 608 | `liveEntityConflict` bloquea por **cualquier** entidad con esa matrícula, sea cual sea el modelo o si tiene marca: un jugador pone con `SetVehicleNumberPlateText` la matrícula de otro en su coche y la víctima ya no puede sacar el suyo del garaje (`vehicle_mismatch`). Harness: FAIL. Las entidades de otros routing buckets también bloquean. | Para filas GARAGED (1), una entidad sin marca no puede ser ese coche → ignorarla y loguearla. Bloquear solo con entidad marcada, o en OUT con `SameModel`. |
| P1-OWN-R2-M2 **APLAZADO a fase 2** | Media | server/vehicles.lua:84-92 | Transferencia con el comprador offline: la entidad sigue trackeada con `src = vendedor`. Si el vendedor se desconecta, `OnDisconnect` se aplica al coche del comprador (`impound` → multa al comprador). El vendedor sigue conduciendo el coche físico (no se borra; solo se quitan las llaves). | Al transferir sin comprador online, `sp.src = nil` (como en un drop) y aplicar la política del nuevo dueño. Documentar que no se expulsa a los ocupantes. |
| P1-OWN-R2-M3 **CERRADO (2b60c36)** | Media | server/vehicles.lua:107-115 | `FrameworkOwner` usa `UPPER(TRIM(plate))`: no usa el índice → **full scan** de `owned_vehicles`/`player_vehicles` en cada store/park (con miles de filas, ms de BD por petición). | Columna generada o comparar por `plate` exacto + la variante con relleno; o cachear el dueño 5 s. |
| P1-OWN-R2-L1 | Baja | server/vehicles.lua:107 vs shared/utils.lua:5 | `NormalizePlate` colapsa los espacios internos y `TRIM` no: una matrícula del framework con doble espacio interno no coincide → `fwOwner = nil` → no se comprueba el dueño del framework. | Normalizar igual en SQL (`REPLACE`) o guardar `plate_norm`. |
| P1-OWN-R2-L2 **PARCIAL (2b60c36)**: regularize cuenta solo las del dueño actual; la venta en estado 3 sigue pendiente de Security | Baja | server/vehicles.lua:99 (estado 3) | Vender un coche incautado: las multas se quedan con el vendedor (`mdp_fines.owner`) y el comprador recibe un coche en el depósito. `/mdp_regularize` mira las multas por `plate`, `takeOut` por `owner` (incoherente). **Decisión de Security.** | Bloquear la transferencia en el estado 3 o definir quién paga; unificar el criterio de multas. |
| P1-OWN-R2-L3 | Baja | server/security.lua:712 | `Security.RegisterExternalVehicle(netId, plate, ownerSrc)` (8a4e3cf) es una segunda implementación que no se exporta. La que sí se exporta (garages.lua:≈640) no liga el dueño (M3 sigue abierto). | Una sola implementación con `ownerSrc` obligatorio. |
| P1-OWN-R2-L4 | Baja | shared/config.lua:128 | `TrustedResources = {}` por defecto: los dos exports quedan desactivados hasta configurarlos (cambio incompatible para quien ya usaba `SpawnOwnedVehicle`). Ningún adaptador interno los llama. | Nota en las release notes (el mensaje de error ya explica cómo añadirlo). |

## Desde QA frontend fase 1 R4 (16/10/2026, 6af6947)
- **Cerrados:** P1F-R3-M1, P1F-R3-L1.
- **Sigue abierto:** P1F-R2-L1 → se sigue como P1F-R4-L1.

| # | Severidad | Archivo:línea | Descripción | Arreglo |
|---|---|---|---|---|
| P1F-R4-L1 | Baja | web/README.md:89-95, docs/release-notes.md:32-33, README.md | `ox:callbackTimeout` solo está en la guía de la NUI y contradice release-notes ("opcional, súbelo"); es un convar global de ox_lib. | Decidir recomendado u opcional y documentarlo en el README raíz (server.cfg) y en release-notes, coherente; corregir "súbelo" por "bájalo". |

## Desde QA Propiedad R3 (16/10/2026, 2b60c36)
Cerrados: R2-M1, R2-M3, M5 (fail-closed sin columna de fecha). Parcial: R2-L2. Aplazados a fase 2: R2-M2 y TR-3..TR-5 (Backend). Siguen abiertos: R2-L1, M1, M3, M4.

| # | Severidad | Archivo:línea (2b60c36) | Descripción | Arreglo |
|---|---|---|---|---|
| P1-OWN-R3-M1 | Media | server/persistence.lua:133-137,185 + garages.lua:134 | Tras el cambio de R2-M1 puede haber clon + coche real del mismo modelo en el mundo. En el siguiente reinicio, los dos coinciden → "ambiguous": no se adopta ninguno → el real queda sin trackear y el dueño no puede guardarlo (`vehicle_mismatch`). Un griefer puede provocarlo manteniendo un clon. | En el reinicio, si exactamente uno tiene la marca del servidor válida, adoptar ese e ignorar los no marcados. |
| P1-OWN-R3-M2 | Media | server/vehicles.lua:120-135 | `FrameworkOwner` con 2 filas → `nil` → la comprobación del framework se salta (falla en abierto) y se usa el dueño de mdp. | Con `ambiguous`, rechazar el store/park (`not_owner`) y loguear. |
| P1-OWN-R3-L1 | Baja | server/vehicles.lua:86-93 | La revocación de llaves recorre todos los jugadores online (`RemoveKeys` × jugadores) en cada transferencia; un sync masivo multiplica las llamadas, y se hace dentro del lock de la matrícula. | Revocar solo al vendedor + los holders conocidos, o hacerlo fuera del lock / en lote. |
| P1-OWN-R3-L2 | Baja | server/vehicles.lua:299-304 | `SyncRemovals` sigue con `UPPER(TRIM(plate))` (full scan) y transfiere solo en los estados 1/2 con su propio UPDATE, no con `ApplyTransfer` (incoherente con H1). | Usar `FrameworkOwner` + `ApplyTransfer(..., true)`. |

## Desde QA Propiedad R4 (16/10/2026, bb6397a)
Sin cambios en R3-H1 (sigue abierta, ver review). P1-OWN-M4 sigue abierto y ahora afecta a más casos (ver R4-M1). Siguen abiertos: R2-L1, R3-M1, R3-M2, R3-L1, R3-L2, M1, M3.

| # | Severidad | Archivo:línea (bb6397a) | Descripción | Arreglo |
|---|---|---|---|---|
| P1-OWN-R4-M1 | Media | server/vehicles.lua:181-189 + garages.lua:284-291 | Con v6, **cualquier** fila nueva en OUT de un dueño conocido es adoptable aunque el framework no tenga columna de fecha (ESX/QB estándar). Esto amplía M4: un coche tipo 7 creado por un script de cliente con la matrícula y el modelo de esa fila se adopta (solo coches propios). "Nueva para mdp" incluye filas **antiguas** que antes se saltaban y ahora entran por un cambio de configuración (`SkipJobVehicles`, `Migration.VehicleTypes`, plates antes inválidas) o tras un DELETE manual en `mdp_vehicles`. | Exigir que la entidad la haya creado un recurso de servidor (RegisterExternalVehicle / `NetworkGetEntityOwner` + entity lockdown), o como mínimo `sv_entityLockdown` documentado. Marcar `first_seen_at` solo si el owner ya estaba sincronizado **y** la configuración de importación no cambió (hash de la config en `mdp_meta`). |
| P1-OWN-R4-L1 | Baja | server/garages.lua:288 | La ventana empieza en `GREATEST(first_seen_at, fw_date_at)`: si la fecha del framework es anterior a la detección (p. ej. 25 min), la ventana real llega a ~55 min desde la compra. | Inicio = `COALESCE(fw_date_at, first_seen_at)` y exigir además que `first_seen_at` esté dentro de la ventana. |
| P1-OWN-R4-L2 | Baja | server/garages.lua:284-291 | La lógica de la ventana está entera en SQL (`CASE/TIMESTAMPDIFF/GREATEST`) y no hay test que la ejecute (no hay MySQL en QA). | Test de integración con MariaDB en CI, o calcular `in_window` en Lua con los timestamps. |
