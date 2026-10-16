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
