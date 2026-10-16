# QA — NUI fase 0, cuarta pasada (HEAD 6eb551d, incluye bdc2eb9 + 6eb551d)

Pruebas: `git archive HEAD web` → /tmp/qa5; `npm ci` OK; `tsc -b` OK; `vite build` OK → **sha256 idénticos** al `web/dist` commiteado (los 15 ficheros, reproducible). Bundle: JS 558,10 KB / 166,38 KB gzip, CSS 124,82 KB / 18,76 KB gzip (subida por react-aria Table, exigido por el lead → backlog). Smoke test con playwright-core + Chrome headless en `vite dev` (mock) a 1180x680 / 1280x720 / 1920x1080, 0 `pageerror`. Captura: `docs/qa-nui-phase0-r4.png` (arriba 1920x1080 con detalle, abajo 1180x680). También revisé las capturas de Frontend en `/tmp/mdp-shots-r3/` (list, detail, detail-disabled).

## Estado
| ID | Estado | Evidencia |
|---|---|---|
| N10 Tarjeta/Empty a mano (excepción DENEGADA) | CORREGIDO | `VehicleCard.tsx` eliminado → `VehicleTable.tsx` usa `Table` UUI dentro de `TableCard` (`ListView.tsx`); `Empty.tsx` usa `EmptyState` UUI (Header/FeaturedIcon/Content/Title); placa = `Badge type="modern"`; ningún hex en views/App (grep). Restos de layout: header de `App.tsx:94-100` (h1/p) y bloque de stats `DetailView.tsx:67-75` — tipografía/maquetación con tokens, no componentes (backlog NUI-R4-3) |
| N11 color-scheme | CORREGIDO (no verificado en el cliente) | `web/index.html` y `dist/index.html` ya no tienen `color-scheme`; solo `[color-scheme:dark]` en el `Modal` (`App.tsx:89`). Medido: html `normal`, body `normal`, panel `dark`; el lienzo vuelve a ser transparente en headless. **No se puede verificar en el cliente FiveM** (sin entorno) → NUI-R4-4 |
| N12 contador | CORREGIDO | "4 · Vehicles" (excluye el estado 4 y el nuevo estado 5 Removed vía `visibleVehicles`) |
| N13 a11y barras | CORREGIDO | `ProgressBarBase aria-label="Engine 100%"…` (parche UUI aprobado) |
| N14 hint deshabilitado | CORREGIDO | Probado: vehículo en estado 0 → botón deshabilitado + `#takeout-hint` "This vehicle is already out" (`aria-describedby`); 3 → `err_impounded`, 4 → `err_retired` |
| N15 mock | CORREGIDO | mock en inglés |
| Código `occupied` | CORREGIDO | `NUI_ERROR_CODES` = `Constants.ErrorCodes` = `architecture.md` "Error codes" = `err_*` de `i18n.tsx` → **36 = 36 = 36 = 36**, mismo conjunto, `occupied` incluido. Todas las claves de i18n están en `ui` de en.lua y es.lua (en y es idénticos) |
| ESC / Close / takeOut | OK | ESC cierra; Take out en estado 2 → panel cerrado |

## Parches "mdp patch" sobre Untitled UI (APROBADOS por el lead; no bloquean)
Comparados con `untitleduico/react@main` (`diff -w`):
1. `application/empty-state/empty-state.tsx` — quita `import { FileIcon } from "@untitledui/file-icons"`, el subcomponente `FileTypeIcon` (+ el tipo y el registro `EmptyState.FileTypeIcon`); el default de `Illustration` pasa de `"cloud"` a `"box"`. Resto idéntico. **Mínimo y justificado** (tree-shaking: −232 KB; el default cambia porque cloud ya no existe).
2. `shared-assets/illustrations/index.tsx` — solo se registra `box` (se quitan cloud/documents/credit-card). **Mínimo** (−~1100 líneas de SVG).
3. `shared-assets/background-patterns/index.tsx` — solo se registra `circle` (se quitan square/grid/grid-check). **Mínimo** (grid-check eran 2520 líneas).
4. `base/progress-indicators/progress-indicators.tsx` — añade la prop opcional `aria-label` a `ProgressBarBase` y la pasa al elemento progressbar. **Mínimo**, mejora de accesibilidad, retrocompatible.
Ninguno es una reimplementación. El resto de componentes UUI (`table`, `modal`, `badges`, `button`, `featured-icon`, `circle`, `box`) son idénticos a upstream (solo cambia `"use client"`). Recomendación: mantener un `PATCHES.md` con estos 4 diffs para reaplicarlos al actualizar con el CLI.

## Incidencias nuevas

### N16 — Alta (BLOQUEA) — Un clic en una fila no abre el detalle
`web/src/views/VehicleTable.tsx:17-21`: `selectionMode="single"` + `selectionBehavior="replace"` + `onRowAction`. En react-aria, con selectionBehavior `replace` y onRowAction, **un clic solo selecciona y la acción requiere doble clic** (o Enter). Además `selectedKeys` está controlado sin `onSelectionChange`, así que el primer clic no cambia nada visible.
Repro (verificado con playwright): abrir el garaje → clic en "Karin Sultan" → el detalle sigue en "Select a vehicle from the list" (0 botones Take out); doble clic o Enter → se abre. Los jugadores de FiveM usan el ratón con un solo clic → la función principal parece rota.
Arreglo: o `selectionMode="single"` + `onSelectionChange={(keys) => …onSelect}` (y quitar onRowAction), o `selectionMode="none"` + `onRowAction` (un clic = acción) + resaltar la fila seleccionada con `data-selected`/className. Retirados sin cambios (sin onSelect).

### Medias/Bajas → backlog
Añadidas a `docs/backlog-phase1.md` (NUI-R4-1…4): tamaño del bundle (558 KB, aviso de chunk), componentes UUI sin uso vueltos a añadir, layout del bloque de stats, verificación de N11 en el cliente.

## Lo que pasa ✅
- N10–N15 y `occupied` corregidos; contrato de errores sincronizado en las 5 fuentes (36 códigos).
- Solo componentes UUI genuinos o con parches aprobados; ningún color hardcodeado en las vistas.
- Build limpio y reproducible bit a bit; `tsc` limpio; `dist` sin DevToolbar/mock, sin CDN, sin innerHTML.
- Escalado OK en 1180x680 (1121x646), 1280x720 y 1920x1080; ESC/Close/takeOut OK; hint localizado cuando Take out está deshabilitado.

## Veredicto
**La NUI de fase 0 NO está CERRADA**: queda **1 bloqueante (N16, Alta)**, que se arregla en una línea en `VehicleTable.tsx`. Con N16 corregido (y comprobando que un clic abre el detalle), la fase 0 se puede **CERRAR**; el resto va a backlog.
**Parches mdp:** el lead ya los aprobó; los 4 son mínimos (tree-shaking y aria-label), no reimplementaciones. Lo que queda por decidir es solo de proceso: documentarlos (PATCHES.md) y reaplicarlos al actualizar Untitled UI.

---

## R5 — Verificación de 1d13e0e (HEAD)

**Build:** `git archive HEAD web` → /tmp/qa6; `npm ci` OK; `tsc -b` OK; `vite build` OK (JS 558,16 KB / 166,41 KB gzip, CSS 124,82 KB / 18,76 KB gzip); **sha256 idénticos** al `web/dist` commiteado (dist reconstruido en el commit: `index-CYoAvukP.js`). `dist` sin DevToolbar/mock/playwright. `playwright-core` solo en devDependencies.

**N16 — CORREGIDO.** `VehicleTable.tsx`: `onSelectionChange` + `selectedKeys` controlado + `disallowEmptySelection`; los retirados usan `selectionMode="none"`.
- `web/tests/n16-row-select.mjs` (según README, `BASE_URL=http://localhost:5190`): **7/7 PASS** (single click, aria-selected, cambio de fila, focus+Enter, clic en un retirado no abre, retirado no seleccionable, 0 errores).
- Mi propia prueba con Playwright (1180x680): un clic en "Dinka Blista" → detalle + `aria-selected=true`; volver a hacer clic en la misma fila → se mantiene (no se deselecciona); ArrowDown+Enter → "Truffade Adder"; Space sin efecto adverso; clic en "Albany Emperor" (retirado) → no cambia el detalle, `aria-selected` nulo; Take out (estado 2) → panel cerrado; ESC con el foco en la tabla → cerrado; 0 `pageerror`. El estado 5 no se renderiza (`visibleVehicles`).

**UNTITLEDUI_PATCHES.md — OK.** Documenta los 4 parches (empty-state, illustrations/index, background-patterns/index, progress-indicators) con motivo (N3/N13), los ficheros borrados, el procedimiento para reaplicarlos tras el CLI y los diffs exactos (también en ficheros `.patch`). Coincide con mi diff contra upstream de R4.

**Regresiones:** ninguna (N10–N15, `occupied`, escalado, ESC/Close/takeOut siguen bien).

**Nuevas Bajas → backlog** (`NUI-R5-1` cobertura/CI del e2e, `NUI-R5-2` las flechas abren el detalle al navegar). Ninguna Crítica/Alta.

### Veredicto R5
**NUI fase 0: CERRADA.** No queda ninguna incidencia Crítica ni Alta. Pendiente fuera del bloqueo: verificar en el cliente FiveM que el panel es transparente alrededor (N11, `NUI-R4-4`) y el backlog de Bajas.
