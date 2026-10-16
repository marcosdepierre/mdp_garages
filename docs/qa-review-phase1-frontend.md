# QA — Fase 1 frontend (cliente + NUI)

**Commits revisados:** f7f145a, f6f2495 (NUI fase 1), 5a12ada / 9e0ce54 / ac529e3 (contrato, locales, toasts), **fecc05a** (Security F1: busy con xpcall + timeout de 15 s; pcall en UI.Close). Revisado sobre **HEAD 1e5104b** (los commits posteriores, a8fda43/ec0c3b7/1e5104b, solo tocan servidor/docs; `web/` y `client/` = fecc05a). Sin cambios en el código fuente del proyecto.

## Pruebas
- `luac5.4 -p` de client/, shared/ y locales/: OK.
- `npm ci` OK · `tsc -b` OK · `vite build` OK. **Reproducible:** sha256 de los 19 ficheros de `web/dist` idénticos a HEAD. Bundle en chunks: index 73 KB, vendor 81 KB, vendor-react 207 KB, vendor-aria 245 KB → 606 KB JS / 179 KB gzip; CSS 125 KB / 19 KB gzip. Dist sin DevToolbar/mock/playwright; solo URLs de mensajes de error de React/Tailwind.
- `npm run test:e2e`: **28/28 PASS** (n16 7/7, phase1 15/15, r5-flows 6/6) — confirmado.
- Mi propia prueba con Playwright (vite dev + mock y mensajes `postMessage` propios), 0 `pageerror`:
  - Toasts de Lua con el panel cerrado: loading → error con el **mismo id = un solo toast**; `occupied` en es → "Bájate los pasajeros"; 10 toasts con el mismo id → 1; un kind desconocido → info sin crash.
  - `invalid_props` → muestra **"Solicitud rechazada"** (ver P1F-M1).
  - Intl: es → `1.234.568 km`, `2.500 $`, fecha `16/10, 23:41`; en → `2,500 $`, `10/16, 11:41 PM`; `release_after` pasado/null → `available_now`.
  - Clamp: engine −3000 → 0 %, body 1500 → 100 % (Backend `ClampHealth` −4000..1000 ✔).
  - Embargo (estado 3): bloque §10.1 (motivo, tasa, fecha), sin botón Take out; retirados: sección con hint, no seleccionables.
  - Take out en curso: filas `aria-disabled=true`, el clic en otra fila no cambia el detalle, Close/ESC ignorados (también en e2e).
- Captura: `docs/qa-nui-phase1.png` (1920x1080 detalle + toast de éxito; 1180x680 ficha de embargo).
- **No verificado (sin cliente FiveM):** resmon < 0.02 ms en reposo, ESC/pausa en el juego, toasts sin foco NUI en CEF. Estimación por código: en reposo solo corre el hilo de ox_lib points (Wait 300) + el odómetro (Wait 1500) → debería quedar < 0.02 ms, pero hay que medirlo.

## Checklist F1-G (client/zones.lua)
| Punto | Resultado |
|---|---|
| Solo dentro de la zona | ✅ `lib.points` (radio + 2 m); el servidor valida DIST 10 m |
| Como conductor y solo | ⚠️ conductor sí; "solo" lo comprueba solo el servidor (`occupied`, toast traducido) → P1F-L1 |
| Debounce: mantener/spamear E → un solo `storeVehicle` | ✅ `IsControlJustReleased` + `busy` + el hilo de points queda bloqueado durante el await (no se leen más E). Excepción tras 15 s → P1F-M2 |
| Errores traducidos (incl. `occupied`) | ✅ vía `Utils.ErrorCode` + `err_<code>`; ❌ `invalid_props` → `rejected` (P1F-M1) |
| Sin bucle activo fuera de las zonas | ✅ zonas con ox_lib points; ⚠️ el odómetro es un bucle global lento (P1F-L2) |
| Ningún Wait(0) fuera de la NUI | ✅ el único Wait(0) propio es el de `blockPauseWhileOpen` (solo con la UI abierta); `nearby` por frame solo dentro del radio (ox_lib) |

## fecc05a — busy (Security F1)
- **Errores en el flujo:** `xpcall(fn)` → `busy=false` + toast `server_error` + log. ✅
- **El callback nunca vuelve:** `SetTimeout(15000)` libera `busy`, invalida el token y muestra el toast `timeout`; el resultado tardío se ignora (sin tocar busy). ✅ busy no se queda atascado.
- **Reinicio del recurso:** `busy`/`attempt` son locales → se reinician; los awaits pendientes mueren con el recurso. ✅
- **¿Doble envío por el timeout?** ⚠️ Sí, en un caso: ox_lib espera hasta `ox:callbackTimeout` (300 s por defecto) y el timeout de 15 s libera `busy` con la petición aún en curso. Con E no ocurre (el hilo de points sigue bloqueado en el await), pero `/mdp_park` corre en su propio hilo y puede mandar un segundo `parkWorld`/`storeVehicle` paralelo; además el resultado real tardío no se muestra (el jugador ve "timeout" aunque se haya guardado). El servidor lo neutraliza (WithLock + estado + RATE 1/s) → **Media**, P1F-M2. Relacionado: el await dentro de `nearby` congela todos los points mientras dura → P1F-M3.
- `takeOut`: `pcall(UI.Close)` y `cb(res)` siempre se llaman. ✅

## Flujo take-out §9.1 y ficha §8/§10 (design-system.md)
- Idle/Disabled (hint `err_*`)/Loading (filas, Close y ESC bloqueados, `aria-busy`, cursor progress)/Success (toast + cierre)/Error (toast + bloque inline + Retry solo para los códigos RETRYABLE) ✅. Sin Retry en el toast ni retardo de 1 s para `rate_limited` → P1F-L3.
- Umbrales ≥60 / 30–59 / <30 y `text-error-primary` <30 ✅; km con `useGrouping:'always'` y `lang` del `open`/`toast` (`langTag` es→es-ES, en→en-US) ✅; `—` si no es numérico ✅.
- `open` sin `vehicles` → LoadingIndicator + `getVehicles`; error → EmptyState error + Retry/Close; las respuestas obsoletas se descartan (`loadSeq`) ✅.

## Contrato / paridad
- `Constants.ErrorCodes` = `architecture.md` = `err_*` de i18n = `ui.err_*` en.lua = es.lua → 37 códigos. **`NUI_ERROR_CODES` = 36: falta `invalid_props`** (P1F-M1).
- Claves de i18n ⊂ `ui` en/es; en y es idénticos (las claves nuevas `storing`, `parking`, `taken_out`, `available_now`, `empty_hint`, `impound_reason` llegaron en 5a12ada/9e0ce54, después de f6f2495).
- `open.lang` y la acción `toast` según "NUI additions (Frontend f6f2495)" de architecture.md ✅; `GarageToast` normaliza con `Utils.ErrorCode` ✅.

## Regla Untitled UI
Comparé `src/components/**` con untitleduico/react@main: todos idénticos (sin `"use client"`) salvo los **4 mdp patches aprobados** (empty-state, illustrations/index, background-patterns/index, progress-indicators). El nuevo `loading-indicator.tsx` es idéntico a upstream. Bloques propios aceptados por diseño: error inline §9.4 y bloque de embargo §10.1 (Alerts es PRO), stats §8.2 (decisión NUI-R4-3). **Nuevo:** `sonner` + el contenido del toast maquetado a mano → pendiente de aprobación explícita del lead (P1F-M4; lo pide el Designer y es dependencia del repo de UUI).

## Incidencias
Ninguna Crítica ni Alta. Medias/Bajas añadidas a `docs/backlog-phase1.md`: **P1F-M1** (invalid_props), **P1F-M2** (timeout de 15 s con la petición aún en curso), **P1F-M3** (await dentro de points.nearby), **P1F-M4** (sonner, decisión del lead), **P1F-L1…L5**.

## Veredicto
**Frontend fase 1: APROBADO** (sin bloqueantes). Antes del cierre de fase conviene: (1) que el lead confirme por escrito `sonner` (P1F-M4); (2) arreglar P1F-M1, que se resuelve en una línea; (3) medir resmon y el flujo store/park en un cliente FiveM real, que esta revisión no ha podido verificar.
