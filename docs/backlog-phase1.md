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
