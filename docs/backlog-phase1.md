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
