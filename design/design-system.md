# mdp_garages — Sistema de diseño (NUI)

> Stack: **React + TypeScript + Tailwind CSS v4 + Untitled UI React (solo componentes FREE)**, empaquetado con **Vite**.
> Base: tema oficial de Untitled UI (`styles/theme.css` de [untitleduico/react](https://github.com/untitleduico/react), licencia MIT, commit `1d410cb` revisado el 16/10/2026) en **modo oscuro**. Solo personalizamos la **escala de marca (brand)** y algunos acentos. Todo lo demás (grises, success/warning/error, sombras, radios, espaciado, tipografía) es el de Untitled UI sin tocar.

## 0. Arquitectura e integración

### Build (obligatorio)
React + Tailwind v4 **requiere paso de build**. FiveM sirve archivos estáticos: compilar con Vite y apuntar `ui_page` al resultado.
```
web/            ← proyecto Vite (src/, index.html, package.json)
web/dist/       ← salida de `vite build` (esto es lo que carga FiveM)
```
`fxmanifest.lua`: `ui_page 'web/dist/index.html'` y `files { 'web/dist/index.html', 'web/dist/assets/*' }`.
`vite.config.ts`: `base: './'` (rutas relativas, NUI usa `https://cfx-nui-<recurso>/`), plugin `@tailwindcss/vite`.
Componentes: `npx untitledui@latest add button badge ...` (CLI) o copiar desde el repo; se copian al proyecto, no hay dependencia runtime pesada. Dependencias que arrastran: `react-aria-components`, `tailwind-merge`, `@untitledui/icons`. Para toasts: `sonner` (ya es dependencia del repo de UUI).

### Orden de importación del CSS
Theme de Untitled UI en `web/src/styles/theme.css`. Orden efectivo:
```ts
// web/src/main.tsx
import '@/styles/globals.css'; // @import "tailwindcss"; theme.css; typography.css (Untitled UI)
import '../tokens.css';        // mdp_garages: override — SIEMPRE después
```
Reglas de `web/tokens.css`:
- Solo nombres **reales** de `src/styles/theme.css` (verificados uno a uno): `--font-body`, `--font-display`, `--color-brand-50…950`, y en `.dark-mode`: `--color-focus-ring`, `--color-border-brand`, `--color-text-brand-secondary`, `--color-fg-brand-primary`. Sin variables `--mdp-*`.
- CSS **sin `@layer`** → gana a `@layer theme/base`. No hace falta `@theme` propio: `--font-display` y `--font-body` ya están registrados en el `@theme` de theme.css, así que `font-display`/`font-body` existen y leen el valor sobrescrito.
- Tokens globales en `:root`; los de modo oscuro en `.dark-mode` (mismo selector que theme.css; `<html class="dark-mode">`).
- Las clases semánticas (`bg-brand-solid`, `text-brand-secondary`, `ring-focus-ring`…) heredan el nuevo brand automáticamente.

### Fuentes (self-hosted, sin Google Fonts)
`web/src/assets/fonts/`: subsets **latin** y **latin-ext** en woff2 — `inter-{latin,latin-ext}-{400,500,600,700}-normal.woff2`, `rajdhani-{latin,latin-ext}-{600,700}-normal.woff2` (12 archivos, @fontsource v5 vía jsDelivr) + `OFL-Inter.txt`, `OFL-Rajdhani.txt` (SIL OFL 1.1). Cada `@font-face` lleva el `unicode-range` exacto de fontsource, así el navegador solo descarga latin-ext si aparece un carácter de ese rango (p. ej. ł, ő, ș). Los `@font-face` de tokens.css usan URLs relativas (`./src/assets/fonts/…`); Vite las hashea a `dist/assets/` y con `base: './'` quedan como `url(./…)`, válidas en `cfx-nui-`.

### Consideraciones NUI
- **Resolución base 1920×1080.** Contenedor fijo 1180×680 centrado. Escala: `--app-scale = Math.min(innerWidth/1920, innerHeight/1080)` aplicado con `transform: scale()` en el contenedor (recalcular en `resize`). No usar `vw` para tipografía.
- **Fondo transparente**: `html, body, #root { background: transparent }` (incluido en tokens.css). Solo el panel tiene fondo `bg-primary`.
- Sin dependencias externas pesadas: nada de CDN en runtime. **Fuentes self-hosted** (ver arriba). Iconos: `@untitledui/icons` (tree-shaking).
- CEF de FiveM (Chromium moderno): soporta `oklch`, `color-mix`, CSS nesting → Tailwind v4 OK.
- `user-select: none`, foco por teclado visible, `Esc` cierra (`SetNuiFocus(false,false)`).
- Animaciones ≤ 300 ms y solo `opacity`/`transform` (rendimiento en juego).

## 1. Paleta

### 1.1 Marca (custom) — "MDP Electric Azure"
Nota: theme.css de UUI define brand 50–950 (no existe `--color-brand-25`), por eso la escala empieza en 50.
Azul eléctrico, frío y premium; destaca sobre los neutros de UUI sin chocar con success/warning/error.

| Token | Hex | Uso principal |
|---|---|---|
| `--color-brand-50`  | `#EBF3FF` | |
| `--color-brand-100` | `#D6E7FF` | |
| `--color-brand-200` | `#B2D0FF` | |
| `--color-brand-300` | `#84B2FF` | `text-brand-secondary` (dark, override) |
| `--color-brand-400` | `#5792FF` | `focus-ring`, `border-brand`, `fg-brand-primary` (dark, override) |
| `--color-brand-500` | `#3373FF` | acento, borde de tarjeta seleccionada |
| `--color-brand-600` | `#1F5CF0` | `bg-brand-solid` → **Button primary** |
| `--color-brand-700` | `#1848CC` | hover/pressed |
| `--color-brand-800` | `#193CA3` | |
| `--color-brand-900` | `#1A3480` | |
| `--color-brand-950` | `#101F4F` | fondos de Badge/Featured icon brand en dark |

### 1.2 Capas y texto (Untitled UI dark, sin override; neutros de Tailwind)
| Rol | Variable UUI | Valor dark | Hex aprox. |
|---|---|---|---|
| Fondo app (panel) | `--color-bg-primary` | neutral-950 | `#0A0A0A` |
| Superficie (tarjetas) | `--color-bg-secondary` | neutral-900 | `#171717` |
| Superficie elevada / hover | `--color-bg-tertiary` | neutral-800 | `#262626` |
| Overlay modal | `--color-bg-overlay` | neutral-800 (+opacidad en Modal) | `#262626` |
| Borde fuerte | `--color-border-primary` | neutral-700 | `#404040` |
| Borde suave | `--color-border-secondary` | neutral-800 | `#262626` |
| Texto 1 | `--color-text-primary` | neutral-50 | `#FAFAFA` |
| Texto 2 | `--color-text-secondary` | neutral-300 | `#D4D4D4` |
| Texto 3 | `--color-text-tertiary` | neutral-400 | `#A1A1A1` |
| Texto 4 / placeholder | `--color-text-quaternary` | neutral-500 | `#737373` |

### 1.3 Estados (Untitled UI, sin override)
| Estado | fg (dark) | Hex | Clase/uso |
|---|---|---|---|
| Éxito | `--color-fg-success-primary` = green-500 | `#22C55E` | Badge `success`, barras ≥60 |
| Aviso | `--color-fg-warning-primary` = yellow-500 | `#EAB308` | Badge `warning`, barras 30–59 |
| Peligro | `--color-fg-error-primary` = red-500 | `#EF4444` | Badge `error`, barras <30, botones destructivos |
| Info | marca (`brand`) | `#3373FF` | toasts info |

## 2. Tipografía
- **Cuerpo/UI:** Inter (variable UUI `--font-body`, por defecto).
- **Display (títulos, nombres de vehículo):** **Rajdhani 600/700** → override `--font-display`. Usar clase `font-display` + `uppercase` en títulos de pantalla.
- **Mono (matrícula, porcentajes):** `--font-mono` de UUI.
- Escala: la de UUI (`text-xs` 12, `text-sm` 14, `text-md` 16, `text-lg` 18, `text-xl` 20, `display-xs` 24, `display-sm` 30, `display-md` 36). Pesos: 400 / 500 / 600 / 700.
- Uso: título pantalla `font-display text-display-sm font-bold uppercase`; nombre vehículo en tarjeta `font-display text-xl font-semibold`; en detalle `text-display-md`; etiquetas de barras `text-xs font-semibold uppercase tracking-wider text-tertiary`.

## 3. Espaciado, radios, sombras, movimiento (todo UUI/Tailwind)
- **Espaciado:** escala Tailwind (`--spacing` = 4px): 1=4, 2=8, 3=12, 4=16, 5=20, 6=24, 8=32, 10=40, 12=48. Padding panel `p-6`, gap lista `gap-2`, padding tarjeta `px-4 py-3`.
- **Radios:** `rounded-md` (6) inputs pequeños/matrícula, `rounded-lg` (8) botones/inputs, `rounded-xl` (12) tarjetas/hero, `rounded-2xl` (16) contenedor y modal, `rounded-full` badges.
- **Sombras:** `shadow-xs` botones/inputs, `shadow-lg` tarjeta seleccionada, `shadow-xl` modal, `shadow-2xl` contenedor principal. Foco: `ring-4 ring-focus-ring/24` (patrón UUI).
- **Movimiento:** `duration-100` hover, `duration-200` selección, `duration-300 ease-out` entrada de panel (fade + scale 0.96→1), barras `transition-[width] duration-500`. Respetar `motion-reduce:`.

## 4. Componentes (Untitled UI) — verificación FREE / PRO

Método de verificación: (a) presencia del componente en el repo open-source MIT `github.com/untitleduico/react` (= FREE); (b) página `untitledui.com/react/components/<slug>` con comando `npx untitledui@latest add` público. Revisado 16/10/2026.

| Parte de la UI | Componente UUI exacto | Archivo en repo | Estado | Dónde se confirmó |
|---|---|---|---|---|
| Botones | **Button** (`primary`, `secondary`, `tertiary`, `link-*`, `primary-destructive`, `secondary-destructive`, `tertiary-destructive`) | `components/base/buttons/button.tsx` | FREE | repo + /react/components/buttons |
| Cerrar panel/modal | **CloseButton** (Buttons) | `components/base/buttons/close-button.tsx` | FREE | repo |
| Estado del vehículo, categoría | **Badge**, **BadgeWithDot** (`type="pill-color"`) | `components/base/badges/badges.tsx` | FREE | repo + /react/components/badges |
| Motor/carrocería/combustible | **Progress bar** (`ProgressBar`, `ProgressBarBase`) | `components/base/progress-indicators/progress-indicators.tsx` | FREE | repo + /react/components/progress-indicators |
| Filtros | **Tabs** (`Tabs`, `TabList`, `Tab`, `TabPanel`) | `components/application/tabs/tabs.tsx` | FREE | repo + /react/components/tabs |
| Búsqueda | **Input** (con `icon`) | `components/base/input/input.tsx` | FREE | repo + /react/components/inputs |
| Icono destacado / hero | **Featured icon** | `components/foundations/featured-icon/featured-icon.tsx` | FREE | repo + /react/components/featured-icons |
| Garaje vacío | **Empty state** | `components/application/empty-state/empty-state.tsx` | FREE | repo + /react/components/empty-states |
| Confirmaciones | **Modal** (`ModalOverlay`, `Modal`, `Dialog`) | `components/application/modals/modal.tsx` | FREE (primitiva) | repo. ⚠ Los *ejemplos* prediseñados de la página /react/components/modals pueden ser PRO: construir el contenido con Featured icon + Button |
| Carga | **Loading indicator** | `components/application/loading-indicator/loading-indicator.tsx` | FREE | repo |
| Tooltips (atajos) | **Tooltip** | `components/base/tooltip/` | FREE | repo |
| Toasts | **Notifications** | — (no está en repo) | **PRO** ❌ | /react/components/notifications marcada PRO, sin comando `add` público |
| Aviso de incautado | **Alerts** | — (no está en repo) | **PRO** ❌ | no existe en repo open-source |

**Alternativas FREE a los PRO**
- **Toast/notification (PRO)** → `sonner` (`<Toaster theme="dark" position="top-right" />` + `toast.custom()`) renderizando un contenido propio con **Featured icon** + texto + **CloseButton**, usando tokens UUI. `sonner` ya figura como dependencia en el repo de UUI.
- **Alerts (PRO)** → bloque custom `div` con `bg-error-primary border border-error-subtle rounded-xl` + **Featured icon** `color="error"` + **Button**.

### 4.1 Button
| Variante del diseño | Prop UUI | Uso |
|---|---|---|
| Primary | `color="primary"` | Sacar vehículo / Guardar vehículo |
| Secondary | `color="secondary"` | Transferir, Cancelar, Marcar en GPS |
| Ghost | `color="tertiary"` | acciones menores |
| Danger | `color="primary-destructive"` (o `secondary-destructive`) | Pagar incautación, confirmar acción destructiva |
Tamaños: `size="lg"` acción principal del detalle, `md` modales, `sm` lista. Estados: hover/pressed/focus los da UUI; `isDisabled`; `isLoading` (spinner integrado) mientras se espera el callback NUI.
```tsx
<Button color="primary" size="lg" iconTrailing={CornerDownLeft} isLoading={busy}
        isDisabled={v.state !== "stored"} onClick={takeOut} className="flex-1">
  Sacar vehículo
</Button>
```
La etiqueta cambia por contexto: en punto de guardado con vehículo propio cerca → "Guardar vehículo".

### 4.2 Tarjeta de vehículo (composición, no es un componente UUI)
UUI FREE no trae "card": `div` con utilidades semánticas UUI + Badge + Progress bar.
```tsx
<button type="button" aria-pressed={selected}
  className={cx("group grid w-full grid-cols-[1fr_auto] gap-x-3 gap-y-2 rounded-xl border px-4 py-3 text-left transition duration-100",
    selected ? "border-brand bg-tertiary shadow-lg ring-1 ring-brand" : "border-secondary bg-secondary hover:bg-tertiary",
    v.state === "impounded" && "opacity-85")}>
  <span className="font-display text-xl font-semibold text-primary truncate">{v.label}</span>
  <BadgeWithDot type="pill-color" size="sm" color={stateColor[v.state]}>{stateLabel[v.state]}</BadgeWithDot>
  <span className="col-span-2 flex items-center gap-2">
    <span className="rounded-md bg-[#E9EDF3] px-2 py-0.5 font-mono text-xs font-bold tracking-widest text-[#0A0A0A]">{v.plate}</span>
    <Badge type="pill-color" size="sm" color="gray">{v.category}</Badge>
  </span>
  <span className="col-span-2 grid grid-cols-3 gap-2">
    <ProgressBarBase value={v.engine} progressClassName={statColor(v.engine)} className="h-1" />
    <ProgressBarBase value={v.body}   progressClassName={statColor(v.body)}   className="h-1" />
    <ProgressBarBase value={v.fuel}   progressClassName={statColor(v.fuel)}   className="h-1" />
  </span>
</button>
```
| Estado | Texto | Badge `color` |
|---|---|---|
| `stored` | GUARDADO | `success` |
| `out` | FUERA | `warning` |
| `impounded` | INCAUTADO | `error` |

### 4.3 Barras de estado (Progress bar)
Valores 0–100. Umbrales: **≥60 verde** (`bg-fg-success-primary`), **30–59 ámbar** (`bg-fg-warning-primary`), **<30 rojo** (`bg-fg-error-primary`). Por defecto UUI usa `bg-fg-brand-primary`; se sobreescribe con `progressClassName`.
```tsx
const statColor = (n:number) => n >= 60 ? "bg-fg-success-primary" : n >= 30 ? "bg-fg-warning-primary" : "bg-fg-error-primary";
<div className="flex flex-col gap-1.5">
  <div className="flex justify-between"><span className="text-xs font-semibold uppercase tracking-wider text-tertiary">Motor</span>
    <span className={cx("font-mono text-sm", engine < 30 ? "text-error-primary" : "text-primary")}>{engine}%</span></div>
  <ProgressBarBase value={engine} progressClassName={statColor(engine)} className="h-2" />
</div>
```
Etiquetas: Motor, Carrocería, Combustible. (FiveM: motor/carrocería vienen 0–1000 → dividir entre 10.)

### 4.4 Modal (confirmaciones: transferir, pagar incautación)
```tsx
<ModalOverlay isOpen={open} onOpenChange={setOpen} isDismissable>
  <Modal>
    <Dialog>
      <div className="w-full max-w-100 rounded-2xl bg-primary p-6 shadow-xl ring-1 ring-secondary">
        <FeaturedIcon icon={AlertTriangle} color="error" theme="light" size="lg" />
        <h2 className="mt-4 text-lg font-semibold text-primary">Recuperar vehículo incautado</h2>
        <p className="mt-1 text-sm text-tertiary">Se cobrarán $2.500 de tu cuenta bancaria.</p>
        <div className="mt-6 flex gap-3">
          <Button color="secondary" size="lg" className="flex-1" onClick={close}>Cancelar</Button>
          <Button color="primary-destructive" size="lg" className="flex-1" onClick={pay}>Pagar</Button>
        </div>
      </div>
    </Dialog>
  </Modal>
</ModalOverlay>
```
`CloseButton` arriba a la derecha. Esc y clic fuera cierran (react-aria).

### 4.5 Toasts (alternativa FREE a Notifications PRO)
`sonner` + Featured icon. Tipos y color de icono: success→`success`, error→`error`, warning→`warning`, info→`brand`. Duración 4 s, máx. 3 visibles, arriba-derecha, fuera del contenedor escalado (escalar con `--app-scale`).
```tsx
toast.custom((id) => (
  <div className="flex w-85 items-start gap-3 rounded-xl bg-secondary p-4 shadow-lg ring-1 ring-secondary">
    <FeaturedIcon icon={CheckCircle} color="success" theme="dark" size="sm" />
    <div className="flex-1"><p className="text-sm font-semibold text-primary">Vehículo guardado</p>
      <p className="text-sm text-tertiary">Buffalo STX · LSPD 019</p></div>
    <CloseButton size="sm" onClick={() => toast.dismiss(id)} />
  </div>
));
```

### 4.6 Estado vacío y estado incautado
- **Vacío:** `EmptyState` (FREE) con `FeaturedIcon` (`gray`, icono `Car01`), título "No hay vehículos en este garaje", descripción "Guarda un vehículo cerca del punto para verlo aquí.", acción `Button secondary` "Cerrar". También para filtros sin resultados ("Sin resultados para «xyz»" + Button tertiary "Limpiar búsqueda").
- **Incautado:** en la tarjeta Badge `error` + opacidad 85 %. En detalle: bloque aviso custom (alternativa a Alerts PRO) con quién incautó, multa y depósito; botones `primary-destructive` "Pagar y recuperar ($X)" → Modal de confirmación, y `secondary` "Marcar en GPS". El botón "Sacar vehículo" se oculta.

## 5. Wireframe — pantalla principal

SVG: `docs/wireframes/garage-main.svg` (copia en `design/`).

```
 ┌──────────────────────────────────────────────────────────────────────────────────────┐
 │ GARAJE CENTRAL — PILLBOX   (font-display)                              [✕] CloseButton│
 │ 8 vehículos · 5 guardados · 2 fuera · 1 incautado  (text-tertiary)                   │
 ├────────────────────────────────┬─────────────────────────────────────────────────────┤
 │ [Todos 8|Guardados|Fuera|Incau]│ PEGASSI ZENTORNO          (●GUARDADO) BadgeWithDot  │
 │   ↑ Tabs (button-gray)         │ Matrícula MDP 4821 · Súper · Garaje Central         │
 │ [⌕ Buscar nombre/matrícula   ] │ ┌─────────────────────────────────────────────────┐ │
 │   ↑ Input (icon)               │ │          ( 🚗 )  Featured icon brand xl          │ │
 │ ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓ │ │          / imagen del modelo (hero)             │ │
 │ ┃Pegassi Zentorno (●GUARDADO)┃ │ └─────────────────────────────────────────────────┘ │
 │ ┃[MDP 4821] (Súper)          ┃ │ MOTOR                                          92%  │
 │ ┃▬▬▬▬▬  ▬▬▬▬   ▬▬           ┃ │ ██████████████████████████████████████████░░░  ← Progress bar
 │ ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛ │ CARROCERÍA                                     73%  │
 │  ↑ tarjeta seleccionada        │ ███████████████████████████████░░░░░░░░░░░░░        │
 │    (div + Badge + ProgressBar) │ COMBUSTIBLE                                    41%  │
 │ ┌────────────────────────────┐ │ ██████████████████░░░░░░░░░░░░░░░░░░░░░░ (ámbar)    │
 │ │Bravado Buffalo STX (●FUERA)│ │                                                     │
 │ │[LSPD 019] (Muscle)         │ │                                                     │
 │ └────────────────────────────┘ │ ┌───────────────────────────────────┐┌────────────┐ │
 │ ┌────────────────────────────┐ │ │      Sacar vehículo  ↵            ││ Transferir │ │
 │ │Karin Sultan RS (●INCAUTADO)│ │ └───────────────────────────────────┘└────────────┘ │
 │ │[7XK 22B]                   │ │   Button primary lg (flex-1)       Button secondary │
 │ └────────────────────────────┘ │                                                     │
 └────────────────────────────────┴─────────────────────────────────────────────────────┘
   420 px                             resto (≈760 px)            contenedor 1180×680
                                               ┌──────────────────────────────┐
  Toast (arriba-dcha, fuera del panel):        │ (✓) Vehículo guardado     [✕]│ sonner +
                                               │     Buffalo STX · LSPD 019   │ Featured icon
                                               └──────────────────────────────┘
```

**Estado vacío** (columna lista + detalle sustituidos por Empty state):
```
 ├──────────────────────────────────────────────────────────────────────────┤
 │                             ( ∅ )   ← Featured icon gray                 │
 │                  No hay vehículos en este garaje                         │
 │         Guarda un vehículo cerca del punto para verlo aquí.              │
 │                         [ Cerrar ]  ← Button secondary                   │
 │                         ↑ Empty state (FREE)                             │
```

**Vehículo incautado** (panel de detalle):
```
 │ KARIN SULTAN RS                              (●INCAUTADO) Badge error    │
 │ ┌──────────────────────────────────────────────────────────────────────┐ │
 │ │ (⚠) Incautado por LSPD · Multa $2.500 · Depósito Municipal           │ │ ← div custom + Featured icon error
 │ └──────────────────────────────────────────────────────────────────────┘ │   (alternativa FREE a Alerts PRO)
 │ MOTOR 22% ██░░░░░ (rojo)  ...                                            │
 │ [ Pagar y recuperar ($2.500) ]  [ Marcar en GPS ]                        │
 │   Button primary-destructive → Modal    Button secondary                 │
```

## 6. Interacción
- Teclado: ↑/↓ cambia selección en la lista, Enter = acción principal, Esc = cerrar, Ctrl+F = foco en búsqueda.
- Al abrir: selecciona el primer vehículo `stored`. Al sacar: `isLoading` en el botón → cierra NUI en éxito → toast success; en error toast error y panel abierto.
- Textos vía `locales/` (es/en); no hardcodear cadenas.
