# mdp_garages — NUI (phase 0 skeleton)

React 19 + TypeScript + Tailwind CSS v4 + Vite, components from **Untitled UI React** (free, MIT).
Dark mode is on by default (`class="dark-mode"` on `<html>`). Built output: `web/dist/` (**committed**: FiveM serves it directly, nothing is built on the server).

## Structure
```
web/
  index.html            Vite entry (html.dark-mode)
  vite.config.ts        base './' (CEF needs relative paths), outDir 'dist'
  tokens.css            Designer-owned (--mdp-*), imported after the Untitled UI theme
  src/
    main.tsx, App.tsx   bootstrap; visibility, ESC, message handlers
    types/index.ts      NUI contract types (mirrors docs/architecture.md)
    nui/env.ts          isInGame, resourceName
    nui/fetchNui.ts     fetchNui()
    nui/useNuiMessages.ts  window 'message' dispatcher + emitNui() (dev)
    router.tsx          useRouter(): navigate/back/reset (state-based)
    views/              ListView, DetailView (PLACEHOLDERS)
    dev/mock.ts         mock garages/vehicles + mock callback responses
    dev/DevToolbar.tsx  browser-only toolbar
    components/base/    Untitled UI (added by CLI): buttons, badges
    components/foundations/dot-icon.tsx, utils/   Untitled UI deps
    styles/             Untitled UI theme (globals.css, theme.css, typography.css)
  _legacy/              old vanilla skeleton (safe to delete)
```

## Develop
```bash
cd web
npm install
npm run dev        # http://localhost:5173 — browser mode: auto-opens with mock data + dev toolbar
npm run typecheck  # tsc
npm run build      # tsc + vite build → web/dist (commit it)
```
Browser mode = no `GetParentResourceName` and no `window.invokeNative`. `fetchNui` then returns mocks from `src/dev/mock.ts`.
Adding Untitled UI components: `npx untitledui@latest add <name> -y` (free components only).

## API
- `fetchNui<E>(event, data): Promise<{ ok, error?, data? }>` — POST `https://${GetParentResourceName() ?? 'mdp_garages'}/${event}`. Typed for `close`, `getVehicles`, `takeOut`.
- Messages (`SendNUIMessage`): `open {view, data: {garage, vehicles}}`, `update {data, view?}`, `close`.
- ESC / Close button → hide + `fetchNui('close', {})`. `takeOut` with `ok` hides the UI (Lua closes focus too).
- Router: `const r = useRouter(); r.navigate('detail', {plate}); r.back(); r.reset('list');`

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
Always call `cb(...)` with `{ ok, error?, data? }`; error codes are listed in `src/types/index.ts`.

## fxmanifest
```lua
ui_page 'web/dist/index.html'
files {
    'web/dist/index.html',
    'web/dist/**/*',
}
```
