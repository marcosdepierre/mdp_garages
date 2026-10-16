# QA — NUI fase 0, tercera pasada (commit 2cc9f9e; Backend dcc5e00)

Pruebas: `git archive 2cc9f9e web` → /tmp/qa4, `npm ci` OK, `tsc -b` OK, `vite build` OK (JS 357,10 KB / 110,79 KB gzip; CSS 107,32 KB / 16,21 KB gzip). Smoke test con playwright-core + Chrome headless en `vite dev` (mock) a 1180x680, 1280x720 y 1920x1080: 0 `pageerror`; panel 1121x646 a 1180x680 y 1180x680 a 1280x720/1920x1080; seleccionar tarjeta → detalle; Take out de un vehículo en estado 2 → panel cerrado. Captura: `docs/qa-nui-phase0-r3.png` (arriba 1920x1080 con detalle, abajo 1180x680).

## Verificación de afirmaciones
| Hallazgo | Estado | Evidencia |
|---|---|---|
| N1 locales | CORREGIDO | 65 claves de `EN` (i18n.tsx) ⊂ `ui` de en.lua (66) y es.lua (66); en/es tienen el mismo conjunto; `err_<code>` existe para los 35 códigos en los dos idiomas; todas las claves `t('…')` usadas existen |
| N2 recuperación de foco | CORREGIDO | `client/main.lua` `blockPauseWhileOpen`: `UI.Close()` (envía `close` a la NUI), comprobado cada 500 ms |
| N3 bundle | CORREGIDO | 952 KB → 357 KB (111 KB gzip); sin `@untitledui/file-icons`, ilustraciones ni patrones; dependencias sin uso eliminadas |
| N4 códigos de error | CORREGIDO | `NUI_ERROR_CODES` (types/index.ts) == `Constants.ErrorCodes` (shared/constants.lua) == `architecture.md` "Error codes" — 35 = 35 = 35, mismo conjunto (diff vacío); `normalizeError` mapea lo desconocido → `rejected` |
| N5 embargo | CORREGIDO (coherente con Backend) | NUI: take out en estados 1-2; 3 solo visualización. Backend: `takeOut` GAR solo `{public,private}`, estado 2 como red de seguridad (`in_use`/`vehicle_moved`), liberación pagada en fase 5 (`architecture.md:321`, código `impounded`). Ver N14 (UX) |
| N6 open sin garage | CORREGIDO | Lua `UI.Open` rechaza si falta `data.garage.id` (return false); la NUI además exige `garageId` para `canTakeOut` |
| N7 visual | CORREGIDO | layout de dos columnas según wireframe, título display, detalle sin tabla vacía |
| N8 ESC → pausa | CORREGIDO | sigue desactivando 199/200 durante 250 ms después del cierre (solo revisión de código; no hay cliente) |
| N9 reproducible | CORREGIDO | versiones fijadas + `@import "tailwindcss" source("../")`; build limpio con `npm ci` → **sha256 idénticos** en los 15 ficheros de `web/dist` frente al commit |
| innerHTML / CDN | OK | 0 en src; 3 internos de React en dist; solo URLs de mensajes de error de React/Tailwind; DevToolbar/mock ausentes del dist |

## Componentes: ¿Untitled UI?
UUI genuinos usados: `Modal/ModalOverlay/Dialog`, `Button` (+ `@untitledui/icons`), `Badge`/`BadgeWithDot`, `ProgressBarBase`, `FeaturedIcon`. **Hechos a mano** (incumplen la regla dura salvo OK explícito del lead):
1. `web/src/views/VehicleCard.tsx:16-37` — **toda la tarjeta**: `<button>` propio con bordes/estados/hover/selección/focus, y una "placa" con colores hardcodeados `bg-[#E9EDF3] text-[#0A0A0A]` (`:31`, fuera de tokens). El comentario cita design-system §4.2 ("div custom con tokens UUI"): el diseño lo permite, la regla del lead no.
2. `web/src/views/Empty.tsx:8-19` — reimplementación de EmptyState ("text styles copied"), en vez de usar el componente.
3. `web/src/App.tsx:87-93` — header (h1 + subtítulo) y `:94` layout de 2 columnas, panel de detalle con borde (`:98`).
4. `web/src/views/DetailView.tsx:50-58` (título/subtítulo) y `:60-69` bloque de stats (labels + valores; la barra sí es UUI).
5. `web/src/views/ListView.tsx:26-27` — cabecera de sección "Retirados" (h2 + p).
(3)-(5) son tipografía/layout con tokens; (1) y (2) son componentes propios de verdad.

## Incidencias nuevas

### N10 — Alta (bloqueante hasta decisión) — Tarjeta y Empty hechos a mano
Ver lista. Arreglo: o el lead aprueba por escrito la excepción de §4.2 (tarjeta = composición sobre tokens UUI), o rehacer la fila con un componente UUI gratuito; usar `EmptyState` de UUI importando solo sus subpartes, sin el barrel de ilustraciones (p. ej. copiar empty-state.tsx sin `FileIcon`/patrones, que sigue siendo código UUI). Sustituir `#E9EDF3/#0A0A0A` por tokens (`bg-primary_alt`/`text-primary` o `--mdp-*` en tokens.css).

### N11 — Alta — `color-scheme: dark` en `<html>` puede pintar un fondo opaco en CEF
`web/index.html:7` `html{color-scheme:dark}` (nuevo en r3). En Chrome headless la página ya no sale transparente: el lienzo se pinta gris oscuro (r2 sin `color-scheme` salía blanco/transparente; html/body/overlay medidos `rgba(0,0,0,0)`, así que es el lienzo del UA). En FiveM la NUI es un iframe dentro de la página raíz de NUI; Chromium pinta un fondo opaco en iframes cuyo `color-scheme` no coincide con el del padre → riesgo de **tapar el juego entero** con un fondo negro.
Repro: abrir el garaje en el cliente y mirar si el mundo se ve alrededor del panel; en el navegador: comparar las capturas r2 y r3.
Arreglo: quitar `color-scheme:dark` de `html` (ponerlo en `.dark-mode #root` o en el panel) y verificarlo en el juego.

### N12 — Baja — El contador del header incluye los retirados
`App.tsx:79` `vehicleCount = data.vehicles.length` → "5 · Vehículos" con 4 activos + 1 retirado. Usar los activos o mostrar los dos.

### N13 — Baja — Accesibilidad de la tarjeta
`VehicleCard.tsx:33-35`: 3 barras sin etiqueta (motor/carrocería/combustible) ni `aria-label`; la tarjeta deshabilitada (retirada) no explica por qué. Añadir `aria-label`/`title` con `t('engine')` etc.

### N14 — Baja — Sin explicación cuando Take out está deshabilitado
Estados 0 (fuera) y 3 (embargado, en `impound:*`): se puede seleccionar y el botón sale deshabilitado sin texto. Mostrar un hint (`err_already_out` / `err_impounded`) bajo el botón.

### N15 — Baja — Header y "Retirados" mezclan idiomas en el mock
Solo dev (mockLocale parcial: "Vehículos"/"Retirados" junto a "In garage"). En el juego, `Utils.UILocale()` envía la tabla completa → sin impacto; como mucho, completar el mock con es.lua.

## Lo que pasa ✅
- N1, N2, N3, N4, N5, N6, N7, N8, N9 corregidos (tabla arriba).
- Contrato: 35 códigos sincronizados en las 3 fuentes; claves i18n completas en en/es.
- Build reproducible bit a bit con `npm ci`; `tsc` limpio; bundle 111 KB gzip.
- ESC/Close: un único POST; Lua sin cierre por ESC, pausa bloqueada + 250 ms de gracia; la recuperación de foco oculta la NUI.
- fxmanifest → `web/dist`, rutas relativas, fuentes locales, sin CDN, sin innerHTML, sin polling (el hilo Lua solo vive mientras la UI está abierta).
- Escalado correcto a 1180x680 / 1280x720 / 1920x1080.

## Veredicto
**La NUI de fase 0 NO se puede cerrar todavía.** Faltan dos puntos:
1. **N10**: decisión escrita del lead sobre VehicleCard/Empty hechos a mano (o rehacerlos con UUI) — la regla dura dice que hoy es un fallo.
2. **N11**: quitar `color-scheme:dark` del `<html>` y confirmarlo en el cliente.
Con esos dos resueltos (y las Bajas opcionales), se puede cerrar la fase 0.
