# mdp_garages — NUI (phase 0 skeleton)

React 19 + TypeScript + Tailwind CSS v4 + Vite, components from **Untitled UI React** (free, MIT).
Dark mode is on by default (`class="dark-mode"` on `<html>`). Built output: `web/dist/` (**committed**: FiveM serves it directly, nothing is built on the server).

## Structure
```
web/
  index.html            Vite entry (<html class="dark-mode">)
  vite.config.ts        base './' (CEF), outDir 'dist'
  tokens.css            Designer-owned: overrides + local @font-face (src/assets/fonts) — imported LAST in globals.css
  src/
    main.tsx, App.tsx   bootstrap; UUI Modal shell (1180x680, scaled), ESC, message handlers
    scale.ts            scale from 1920x1080, never < 1 while the panel fits (text >= 12px)
    i18n.tsx            t(key): Lua `locale` from 'open' → English fallback (EN); err_<code> per NuiErrorCode
    state.ts            vehicle state → locale key + Badge color (unknown → generic gray)
    types/index.ts      NUI contract (docs/architecture.md), NUI_ERROR_CODES, PLATE_RE / isValidPlate (1-8)
    nui/                env.ts, fetchNui.ts (10 s timeout), useNuiMessages.ts
    router.tsx          useRouter(): navigate/back/reset (state-based)
    views/              ListView, DetailView, VehicleCard, Empty, stats.ts (placeholder-level; layout divs + UUI components)
    dev/                mock.ts + DevToolbar.tsx — DEV ONLY (import.meta.env.DEV), absent from dist
    components/         Untitled UI (CLI, FREE): modals, buttons, badges, progress-indicators, featured-icon, dot-icon.
                        Table/EmptyState removed (QC N3: they pulled ~200 KB of react-aria table + file-icons).
    styles/             Untitled UI theme (globals.css → typography.css → theme.css → ../../tokens.css)
```

## Develop
```bash
cd web
npm ci             # exact versions from package-lock.json (package.json is pinned, .npmrc save-exact=true)
npm run dev        # http://localhost:5173 — dev: auto-opens with mocks + dev toolbar
npm run typecheck  # tsc -b
npm run build      # tsc + vite build → web/dist (commit it; FiveM serves it as-is)
```
**Reproducible build:** `npm ci && npm run build` from a clean checkout gives a byte-identical `dist/` (Tailwind scans only `src/` + `index.html` via `source()`/`@source`). Always rebuild with `npm ci` before committing `dist/`.
Production build outside FiveM shows nothing and fetchNui returns `{ok:false,error:'server_error'}` (no mocks shipped).
Add components: `npx untitledui@latest add <name> -y` (FREE only; Alerts, Section headers are PRO).

## Untitled UI patches
4 approved local patches — see `UNTITLEDUI_PATCHES.md` and `patches/untitledui/`.

## Tests
`tests/n16-row-select.mjs` (playwright-core + system Chrome, mock mode): `npx vite --port 5190 & BASE_URL=http://localhost:5190 npm run test:e2e`. Not part of the build.

## Behaviour / API
- `fetchNui<E>(event, data): Promise<{ ok, error?, data? }>` — POST `https://${GetParentResourceName() ?? 'mdp_garages'}/${event}`, 10 s timeout → `error:'timeout'`.
- Lua → NUI: `open {view, data:{garage, vehicles}, locale?, plate?}`, `update {data (merged), view?, plate?}` (ignored before the first `open`), `close` (hide).
- ESC: `preventDefault` + `fetchNui('close')` only; the panel hides when that callback answers (or times out), or on a Lua `close` message.
- Take out enabled for state 1 (garaged) and 2 (parked_world); 3 impounded = display only; 4 retired = 'Retired' section, no button; disabled if `open` had no `garage`.
- Error codes: `NUI_ERROR_CODES` = docs/architecture.md "Error codes (single source of truth)"; unknown codes → `rejected`.
- Rows: single click (or Enter) selects + opens detail; selected row highlighted; retired rows not selectable.
- `takeOut` ok → hide (Lua `UI.Close()` also sends `close`); error → localized `err_<code>` Badge.
- No `innerHTML` / `dangerouslySetInnerHTML` in our source.

## Lua template
```lua
local function OpenGarageUI(view, data)
    SendNUIMessage({ action = 'open', view = view or 'list', data = data }) -- data = { garage = Garage, vehicles = Vehicle[] }
    SetNuiFocus(true, true)
end
SendNUIMessage({ action = 'update', data = { vehicles = list } })
SendNUIMessage({ action = 'close' }); SetNuiFocus(false, false)

RegisterNUICallback('close', function(_, cb)
    SetNuiFocus(false, false)   -- required, or the cursor stays captured
    cb({ ok = true })
end)
RegisterNUICallback('getVehicles', function(req, cb) cb({ ok = true, data = {} }) end)          -- req.garage_id
RegisterNUICallback('takeOut',     function(req, cb) cb({ ok = true, data = { netId = 0 } }) end) -- req.plate, req.garage_id
```
Send the `ui` locale table in `open`: `locale = UILocale()`. Always call `cb(...)` with `{ ok, error?, data? }`; error codes are listed in `src/types/index.ts`.

## fxmanifest
```lua
ui_page 'web/dist/index.html'
files {
    'web/dist/index.html',
    'web/dist/**/*',
}
```
