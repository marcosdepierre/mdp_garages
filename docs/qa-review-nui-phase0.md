# QA — NUI fase 0 (commit e5504e6)

Revisado contra el commit **e5504e6** ("Initial commit: mdp_garages phase 0"). `web/` del working tree = idéntico a e5504e6 (`git diff e5504e6 -- web` vacío). `client/main.lua` y `fxmanifest.lua` tienen cambios **sin commitear** posteriores a e5504e6 (refactor a `UI` local + exports); se revisa e5504e6 y se anota la diferencia.
Build: `git archive e5504e6 web` → /tmp/qa2; `tsc -b` OK (0 errores); `vite build` OK y **reproducible**: genera exactamente `index-9RuY-DHL.js` / `index-Dbqf3lzd.css`, los mismos hashes que el `web/dist` commiteado. Smoke test headless (google-chrome + vite preview, modo mock) a 1920x1080, 1180x680 y 3840x2160 → `docs/qa-nui-phase0.png`.

## Verificación explícita de lo que afirma Frontend
| Afirmación | Resultado |
|---|---|
| `web/dist/index.html` existe (build React) | ✅ en e5504e6, rutas `./assets/...` |
| `web/_legacy` eliminado | ✅ no existe en el disco ni en el árbol de e5504e6 (el README todavía lo menciona → B5) |
| Sin `innerHTML` en `web/src` | ✅ 0 coincidencias de `innerHTML`/`dangerouslySetInnerHTML` |
| Fuentes locales latin + latin-ext | ✅ 12 woff2 (Inter 400-700, Rajdhani 600/700, latin + latin-ext) en dist; ni una URL de fuentes remotas ni de CDN en el bundle |
| Matrícula 1-8 | ⚠️ `types/index.ts:19` `PLATE_RE=/^[A-Z0-9 ]{1,8}$/` y `config.lua:43` dicen 1-8, pero `docs/architecture.md:150` sigue diciendo 1-12 → M4 |
| Sección "Retirados" (estado 4, sin take-out) | ✅ `ListView.tsx:33-43`; las filas retiradas no tienen botón Details, y `DetailView` además deshabilita Take out si state≠1. Texto hardcodeado → A2 |

## Incidencias

### C1 — Crítica — Componentes que no son de Untitled UI (regla dura)
Los únicos componentes de Untitled UI son `components/base/buttons/button.tsx`, `components/base/badges/*` y `foundations/dot-icon.tsx`. Todo lo siguiente está hecho a mano:
- `src/AppShell.tsx:20-29` — panel/modal (div + scale). Debería ser el Modal/Dialog de UUI.
- `src/App.tsx:43-46` — header de la app (`h1` + layout).
- `src/views/ListView.tsx:16-29` — `Row`: tarjeta de fila de vehículo (div con borde). `:36` `<p>` de cabecera, `:39-40` `section`/`h2` "Retirados".
- `src/views/DetailView.tsx:13,25-27` — `<p>`, `<pre>` con JSON, mensaje de error (debería ser Alert/Feedback de UUI).
- `src/dev/DevToolbar.tsx:7-16` — contenedor de la toolbar (solo dev, impacto menor).
- `src/router.tsx` — router propio (lógica, no UI; aceptable pero lo dejo anotado).
Otras librerías en `package.json`: `tailwindcss-animate`, `@tailwindcss/typography` (plugins CSS, no componentes), `@fontsource/*` (solo fuentes). `react-aria-components` es dependencia de UUI → OK.
Arreglo: `npx untitledui@latest add` modal, card/list item, alert, empty-state, section header; reemplazar los divs. Si las vistas son *placeholders* de fase 0, que el lead lo deje por escrito como excepción temporal.

### A1 — Alta — Doble cierre / carrera ESC (client/main.lua:50-60 @e5504e6)
NUI: `App.tsx:30` en keyup Escape → `requestClose` → `fetchNui('close')` (una sola vez: después `visible=false` y el listener se vuelve a registrar sin efecto). Lua: el hilo de seguridad comprueba `IsDisabledControlJustReleased(0,200)` / `IsControlJustReleased(0,322)` y llama `closeNui(true)` → `SendNUIMessage close`. Si CEF y el juego ven el mismo ESC, el resultado es: NUI hace POST de `close` + Lua manda el mensaje `close` → doble ruta de cierre (inocuo en el estado actual porque el mensaje solo oculta, pero además con foco NUI el ESC puede abrir el menú de pausa en el frame en que se suelta el foco). El POST sigue siendo único.
Repro: abrir el garaje en el juego, pulsar ESC y loguear `closeNui` (verás 2 llamadas: callback + hilo), o ver que se abre el pausa.
Arreglo: en el hilo, `if UI.open` + flag `closing`; en vez de cerrar desde el hilo, solo `DisableControlAction(0,200)`/`(0,322)` mientras UI.open y unos frames después del cierre (p. ej. 200 ms); dejar el cierre por ESC solo a la NUI y que el hilo cierre solo si `not IsNuiFocused()`.

### A2 — Alta — Textos visibles hardcodeados (no hay locales en la NUI)
`App.tsx:45` "Close"; `ListView.tsx:9-13` Out/Garaged/Parked/Impounded/Retired, `:25` "Details", `:36` "List view (placeholder) — N vehicles", `:40` "Retirados" (español mezclado con el resto en inglés); `DetailView.tsx:13` "No vehicle", `:25`, `:28` "Error: {code}" (muestra el código en bruto), `:29` "Back", `:30` "Take out"; `index.html` `lang="en"`.
Arreglo: mandar `locale` (tabla de `locales/*.lua`) en `open` o en un mensaje `setLocale`; `t(key)` en la NUI; mapear `NuiErrorCode` → clave de locale.

### M1 — Media — `update` sin `open` previo rompe el render
`App.tsx:25`: si `data` es null hace `m.data as OpenData`; un `update {vehicles}` sin garage → `data.garage.label` undefined → TypeError (`App.tsx:44`). Repro: en el navegador, cerrar con la toolbar, recargar con la NUI oculta y emitir update antes que open (en el juego: `UI.Update` antes de `UI.Open`). Arreglo: ignorar `update` si `d===null`.

### M2 — Media — Estado desconocido rompe la lista
`ListView.tsx:17` desestructura `stateLabel[v.state]`; si el servidor manda un estado fuera de 0-4 (o un string "1") → crash. Arreglo: fallback `?? ['?', 'gray']` y validación/normalización en `useNuiMessages`.

### M3 — Media — Escala a resoluciones bajas
`AppShell.tsx:7` `scale=min(w/1920,h/1080)` sin límite inferior: a 1180x680 → 0.61, panel ≈720x415 px y texto base de ~8 px (ilegible, ver captura). A 4K escala 2 bien. Arreglo: clamp (p. ej. `max(scale, 0.75)` limitado por que quepa: `min(w*0.95/1180, h*0.95/680)`) y comprobar 1280x720 / 1366x768 / ultrawide.

### M4 — Media — Contrato desincronizado: longitud de matrícula
`docs/architecture.md:150` "1-12 chars" vs `types/index.ts:19,27` y `shared/config.lua:43` "1-8". Además `isValidPlate` (`types/index.ts:20`) no se usa en ningún sitio. Arreglo: actualizar el doc a 1-8 (columna VARCHAR(12)) y usar `isValidPlate` antes de `takeOut`.

### B1 — Baja — `open` con view 'detail' sin plate
`DetailView.tsx:10` cae a `vehicles[0]` en silencio (puede ser un vehículo retirado o embargado). Contrato: añadir `plate?` al mensaje `open`/`update`, o reset a 'list' si falta.

### B2 — Baja — Badge con imagen remota en el código fuente
`components/base/badges/badges.tsx:300` `https://www.untitledui.com/images/flags/...` (variante bandera). No está en el bundle (tree-shaken, 0 coincidencias en dist), pero conviene no usar esa variante jamás en CEF offline.

### B3 — Baja — `fetchNui` no comprueba `resp.ok` ni distingue un JSON inválido
`nui/fetchNui.ts:20`: todo se convierte en `server_error`; aceptable. Opcional: un timeout con AbortController.

### B4 — Baja — Peso de las fuentes / CSS
dist = ~728 KB (JS 306 KB / 95 KB gzip, CSS 112 KB / 17 KB gzip, 12 woff2 ~330 KB). Razonable para NUI local; `@tailwindcss/typography` no parece usarse (eliminar el plugin reduce CSS).

### B5 — Baja — Docs
`web/README.md` sigue listando `_legacy/` y el import de `@fontsource` en `main.tsx`; el comentario de `tokens.css` dice que se importa desde main.tsx (en realidad, desde globals.css).

## Lo que pasa ✅
- (2) `web/dist` commiteado y reproducible; `fxmanifest.lua:54-58` `ui_page 'web/dist/index.html'`, `files { 'web/dist/index.html','web/dist/**/*' }`; `vite base './'`, assets `./assets/*`; fuentes locales, sin fuentes de red ni CDN.
- (3) ESC y el botón Close ocultan la UI y hacen un solo POST de `close`; el mensaje `close` de Lua solo oculta (no hace POST) → no hay bucle. Lua `close` callback libera el foco.
- (4) open/update/close despachados vía `useNuiMessages` (ref estable, ignora las acciones desconocidas); `open` resetea el router; `takeOut` ok → `onClosed` oculta, y Lua cierra el foco (`client/main.lua:45`); error → se muestra el código.
- (5) Tipos = contrato: `VehicleState` 0-4, las formas de Garage/Vehicle/ImpoundInfo, las 11 `NuiErrorCode` iguales a architecture.md, las req/res de `close/getVehicles/takeOut`.
- (7) Sin `innerHTML`/`dangerouslySetInnerHTML`; todo el texto dinámico pasa por JSX (escapado).
- (8) Sin `setInterval`/polling en la NUI (solo listeners de message/keyup/resize); bundle razonable.
- `tsc -b` sin errores; build OK; smoke test en modo mock OK (lista, badges, sección Retirados sin botón, toolbar dev).
