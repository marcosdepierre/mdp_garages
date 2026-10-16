# QA — NUI fase 0, segunda pasada (commit 7c34e12)

Base: commit **7c34e12** ("fix(nui): QC phase0 — Untitled UI components, locale strings, ESC via close callback, dev-only toolbar, fetchNui timeout"). `web/` en disco = 7c34e12. `client/main.lua` tiene 1 cambio sin commitear (`UILocale()` → `Utils.UILocale()`); el global `UILocale` existe en `shared/locale.lua:31` @7c34e12, así que el commit funciona tal cual, pero si el cambio del working tree se commitea sin mover también la función a `Utils`, el `open` rompe (verificarlo).

Pruebas: `git archive 7c34e12 web` → /tmp/qa3, `npm install`, `tsc -b` **OK (0 errores)**, `vite build` **OK**. Smoke test con playwright-core + Chrome headless en `vite dev` (modo mock; en el build de producción no hay mock, como debe ser): 1180x680, 1280x720, 1920x1080, 3840x2160, ESC, detalle, take out, 0 `pageerror`. Captura: `docs/qa-nui-phase0-r2.png` (arriba 1920x1080, abajo 1180x680).

## Autenticidad de Untitled UI
Comparé con `untitleduico/react@main` (raw GitHub, `diff -w`): `modal.tsx`, `table.tsx`, `empty-state.tsx`, `progress-indicators.tsx`, `badges.tsx`, `button.tsx` → **idénticos** salvo la línea `"use client";` quitada. Son genuinos.
Restos hechos a mano (todos son composición/wrappers, sin estilos propios de componente):
- `views/Empty.tsx` — wrapper fino de `EmptyState` (OK).
- `views/DetailView.tsx:~45` — `<div className="px-4 pt-3">` alrededor del Badge de error; `contentTrailing` `<div className="flex gap-2">`.
- `views/ListView.tsx:19` `<div className="flex flex-col gap-6">`; `App.tsx` `<div className="flex-1 overflow-auto p-6">`.
- `router.tsx`, `scale.ts`, `i18n.tsx`, `state.ts` — lógica, no UI.
- `dev/DevToolbar.tsx:7` — contenedor div (solo dev, excluido del dist: verificado, 0 coincidencias de `DevToolbar`/`mockOpen`/datos mock en `dist`).
Veredicto C1: **CORREGIDO** (solo quedan divs de layout; el lead debe confirmar que aceptan layout con utilidades Tailwind).

## Estado de los hallazgos anteriores
| ID | Estado | Nota |
|---|---|---|
| C1 componentes no-UUI | CORREGIDO | ver arriba |
| A1 doble cierre ESC | CORREGIDO | NUI: guard `closing` ref, POST `close` único en keyup, oculta tras la respuesta (`App.tsx:29-35,56-65`). Lua: ya no cierra por ESC; el hilo solo desactiva 199/200 mientras `UI.open` y termina al cerrar (`client/main.lua` `blockPauseWhileOpen`). Nueva incidencia relacionada → N2 |
| A2 textos sin locale | PARCIAL | todo pasa por `t()`, y Lua envía `locale` en `open`. Pero las claves `err_*` (22), `state_unknown` y `select_vehicle` no existen en `locales/en.lua` ni `es.lua` (`ui`) → en español los errores salen en inglés → N1 |
| M1 update antes de open | CORREGIDO | `App.tsx:44-49` ignora y avisa |
| M2 estado desconocido | CORREGIDO | `state.ts` fallback `state_unknown` |
| M3 escala | CORREGIDO | `scale.ts`: 1180x680 → panel 1121x646 (0.95); 1280x720 → 1:1; 4K → 2x. Medido con boundingBox |
| M4 placa 1-8 | CORREGIDO | `architecture.md:209` = 1-8; `isValidPlate` usado en DetailView. Las listas de errores siguen desfasadas → N4 |
| B1 detail sin plate | CORREGIDO | `plate` en `open`/`update`; sin plate → EmptyState |
| B2 badge con imagen remota | NO CORREGIDO (aceptable) | `badges.tsx:300` sigue igual a upstream; no llega al bundle (0 URLs untitledui.com en dist) |
| B3 fetchNui | CORREGIDO | timeout 10 s con AbortController → `timeout`; comprueba `resp.ok` y la forma `{ok:boolean}` |
| B4 tamaño | EMPEORADO | ver N3 |
| B5 docs | CORREGIDO | README reescrito, `_legacy` ya no aparece |
| innerHTML | CORREGIDO | 0 en `src`; las 3 apariciones en dist son internas de React-DOM (confirmado) |

## Incidencias nuevas

### N1 — Alta — Errores y algunos textos solo en inglés
`web/src/i18n.tsx:5-24` define `err_*`, `state_unknown` y `select_vehicle`, pero no están en `locales/en.lua` / `locales/es.lua` → `ui` (@7c34e12). `makeT` hace fallback a `EN` → con `Config.Locale='es'` "No tienes dinero" sale como "You do not have enough money". El mock solo traduce 4 claves (`dev/mock.ts:47`), por eso la captura mezcla "Vehículos/Cerrar" con "Details/In garage".
Repro: `Config.Locale='es'`, take out sin fondos → mensaje en inglés.
Arreglo: añadir todas las claves de `EN` a `ui` en los dos ficheros Lua (que i18n.tsx sea la referencia) + test/script que compare las claves.

### N2 — Media — La recuperación de foco no oculta la NUI
`client/main.lua` `blockPauseWhileOpen`: si `not IsNuiFocused()` llama `setClosed()` (suelta foco y `UI.open=false`) pero **no** envía `SendNUIMessage({action='close'})` → el panel queda visible sin foco, y la NUI cree que sigue abierta (`visible=true`).
Repro: abrir la UI y quitar el foco desde otro recurso (`SetNuiFocus(false,false)` en otro script / alt-tab con ciertos menús) → al pasar 1 s el panel se queda pintado e inerte.
Arreglo: usar `UI.Close()` en vez de `setClosed()` en esa rama.

### N3 — Media — Bundle triplicado (952 KB JS / 221 KB gzip; CSS 133 KB)
Antes 306 KB. Sourcemap: `react-aria` 749 KB fuente, `shared-assets` (ilustraciones + `grid-check.tsx` de 2520 líneas) 267 KB, `@untitledui/file-icons` 232 KB. Causa: `empty-state.tsx` importa estáticamente todas las ilustraciones, patrones y `FileIcon`, aunque solo se usa `type="box"` + `pattern="none"`. Vite avisa de chunk >500 KB.
Arreglo: importar directamente `illustrations/box` en `Empty.tsx` usando las subpartes (o una copia reducida de `EmptyState` sin `FileIcon`/patrones); quitar los componentes añadidos sin uso (avatar, checkbox, dropdown, input, tabs, toggle, tooltip, radio) y las dependencias `input-otp`, `@tailwindcss/typography`. Es local en CEF (no crítico), pero alarga el parse en el primer open.

### N4 — Media — Contrato de errores desincronizado
`types/index.ts` `NUI_ERROR_CODES` no tiene `wrong_vehicle_type` ni `invalid_state` (sí en `architecture.md:237`), y tiene `timeout` (no está en el doc). Además `locales/*.lua` usan `err_retired_vehicle`/`err_busy` y la NUI `err_retired`/`err_rate_limited`.
Arreglo: una sola lista (añadir los 2 códigos + claves; documentar `timeout` como solo-NUI).

### N5 — Media — En un garaje de embargo no se puede sacar nada
`DetailView.tsx` `canTakeOut = state === Garaged`; en `impound:*` todos los vehículos son estado 3 → botón siempre deshabilitado. Si el pago de la multa y la recuperación en el depósito son de una fase posterior, documentarlo; si no, permitir `Impounded` cuando `garage.kind==='impound'` (el servidor valida el fee).
Repro: toolbar dev "open impound" → Details → Take out deshabilitado.

### N6 — Baja — `open` con `data={}` (Lua por defecto) → crash al sacar
`client/main.lua` `UI.Open` envía `data or {}`; `App.tsx:39` acepta `garage: undefined`; `DetailView` `data.garage.id` → TypeError al pulsar Take out. Arreglo: no abrir (o mostrar Empty) si falta `garage`.

### N7 — Baja — Detalles visuales
- `App.tsx` `TableCard.Header` del garaje: el título sale pequeño (~13 px, `text-md` de TableCard) frente al diseño (display grande); ver captura.
- `DetailView` tabla con `Table.Head label=""` → franja de cabecera vacía (captura de detalle).
- Dev: el `ModalOverlay` de react-aria vuelve inert lo de fuera → la DevToolbar no responde mientras el modal está abierto (los botones "unknown state"/"update" no hacen nada); a 1180x680 además la tapa. Solo dev.

### N8 — Baja — Pausa tras cerrar
El hilo deja de desactivar 199/200 en el mismo frame en que se cierra; según el timing de CEF puede filtrarse un ESC al menú de pausa. Sugerencia: seguir desactivando ~250 ms después de `UI.open=false`. (No reproducible sin cliente; solo revisión de código.)

### N9 — Baja — Build no reproducible bit a bit
El build limpio en /tmp genera otro hash y un CSS de 157 KB frente a 133 KB en el dist commiteado (el escaneo de fuentes de Tailwind depende del entorno/.gitignore). Funciona, pero conviene `@source` explícito en `globals.css` y hacer el build desde un checkout limpio.

## Lo que pasa ✅
- Componentes Untitled UI genuinos (diff con upstream), DevToolbar y mocks fuera del dist.
- `fxmanifest` ui_page/files → `web/dist`, base `./`, fuentes locales latin+latin-ext, sin CDN (solo URLs de mensajes de error de React/Tailwind en comentarios/strings).
- ESC/Close: un único POST `close` (guard), oculta tras la respuesta o el timeout; Lua no cierra por ESC; pausa bloqueada mientras está abierta.
- open/update/close, router list/detail con `plate`, takeOut ok → oculta (+ Lua `UI.Close`); verificado en mock.
- Escalado correcto en 1180x680, 1280x720, 1920x1080 y 4K.
- Sin innerHTML/dangerouslySetInnerHTML en src; sin polling; fetchNui con timeout de 10 s.
- `tsc -b` y `vite build` sin errores; 0 errores de runtime en el smoke test.
