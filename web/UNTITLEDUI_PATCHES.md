# Untitled UI patches (mdp_garages)

All components under `src/components/` come from the official CLI (`npx untitledui@0.1.69 add <name> -y`).
**Only the 4 files below differ from the CLI output** (verified: every other file in `src/components/` is
byte-identical to a fresh `untitledui@0.1.69 init --vite -y` + `add table modal button badges empty-state progress-indicators -y`).
Patches were approved by the Senior Developer (QC r4). Each change is tagged `mdp patch` in the source.

| File | QC item | Reason |
|---|---|---|
| `src/components/application/empty-state/empty-state.tsx` | N3 | Removes `FileTypeIcon` and its static `@untitledui/file-icons` import (~232 KB, unused, kept alive by `EmptyState.FileTypeIcon = …`). Default `Illustration` type changed `"cloud"` → `"box"` because only `box` is bundled. |
| `src/components/shared-assets/illustrations/index.tsx` | N3 | Barrel registers only `box`; `cloud`, `credit-card`, `documents` files deleted. |
| `src/components/shared-assets/background-patterns/index.tsx` | N3 | Barrel registers only `circle`; `grid`, `grid-check` (2.5k lines), `square` files deleted. |
| `src/components/base/progress-indicators/progress-indicators.tsx` | N13 | `ProgressBarBase` accepts and forwards `aria-label` to the `role="progressbar"` element (upstream drops it). |

Also removed vs. CLI output (whole files, not patched): `shared-assets/illustrations/{cloud,credit-card,documents}.tsx`,
`shared-assets/background-patterns/{grid,grid-check,square}.tsx`, and the `@untitledui/file-icons` dependency.

Patch files (unified diffs vs. CLI 0.1.69 output, apply from `web/` with `patch -p1`): `patches/untitledui/*.patch`.

## How to reapply after updating Untitled UI
```bash
cd web
npx untitledui@<new> add empty-state progress-indicators -y --overwrite   # overwrites the 4 files
for p in patches/untitledui/*.patch; do patch -p1 --dry-run < "$p" && patch -p1 < "$p"; done
rm -f src/components/shared-assets/illustrations/{cloud,credit-card,documents}.tsx \
      src/components/shared-assets/background-patterns/{grid,grid-check,square}.tsx
npm rm @untitledui/file-icons
npm run build    # tsc must pass; check bundle has no file-icons
```
If a patch no longer applies (upstream changed), redo the change by hand following the table above, then
regenerate the patch: diff a fresh CLI copy against `src/components/<file>` (`diff -u --label a/src/components/<f> --label b/src/components/<f>`).

## Exact diffs vs. upstream (untitledui CLI 0.1.69)

### application_empty-state_empty-state.patch
```diff
--- a/src/components/application/empty-state/empty-state.tsx
+++ b/src/components/application/empty-state/empty-state.tsx
@@ -1,6 +1,6 @@
-import type { ComponentProps, ComponentPropsWithRef, ReactNode } from "react";
+import type { ComponentPropsWithRef, ReactNode } from "react";
 import { Children, createContext, isValidElement, useContext } from "react";
-import { FileIcon } from "@untitledui/file-icons";
+// mdp patch (QC N3): FileTypeIcon / @untitledui/file-icons removed (232 KB, unused).
 import { SearchLg } from "@untitledui/icons";
 import { FeaturedIcon as FeaturedIconbase } from "@/components/foundations/featured-icon/featured-icon";
 import type { BackgroundPatternProps } from "@/components/shared-assets/background-patterns";
@@ -31,7 +31,7 @@
     return <FeaturedIconbase {...props} {...{ color, theme, icon }} size={!size && rootSize === "lg" ? "xl" : size || "lg"} />;
 };
 
-const Illustration = ({ type = "cloud", color = "gray", size = "lg", ...props }: ComponentPropsWithRef<typeof Illustrations>) => {
+const Illustration = ({ type = "box", /* mdp patch: was "cloud" */ color = "gray", size = "lg", ...props }: ComponentPropsWithRef<typeof Illustrations>) => {
     const { size: rootSize } = useContext(RootContext);
 
     return (
@@ -45,21 +45,6 @@
     );
 };
 
-interface FileTypeIconProps extends ComponentPropsWithRef<"div"> {
-    /** Which file type the icon depicts, forwarded to `FileIcon` from `@untitledui/file-icons`. */
-    type?: ComponentProps<typeof FileIcon>["type"];
-    /** Drawing style of the file icon, forwarded to `FileIcon` as its `variant`. */
-    theme?: ComponentProps<typeof FileIcon>["variant"];
-}
-
-const FileTypeIcon = ({ type = "folder", theme = "solid", ...props }: FileTypeIconProps) => {
-    return (
-        <div {...props} className={cx("relative z-10 flex rounded-full bg-linear-to-b from-neutral-50 to-neutral-200 p-8", props.className)}>
-            <FileIcon type={type} variant={theme} className="size-10 drop-shadow-sm" />
-        </div>
-    );
-};
-
 interface HeaderProps extends ComponentPropsWithRef<"div"> {
     /** Decorative background pattern drawn behind the header's icon or illustration and centred on it. Pass `"none"` to render the header without a pattern. */
     pattern?: "none" | BackgroundPatternProps["pattern"];
@@ -333,7 +318,6 @@
     Description: typeof Description;
     Illustration: typeof Illustration;
     FeaturedIcon: typeof FeaturedIcon;
-    FileTypeIcon: typeof FileTypeIcon;
     AvatarRadius: typeof AvatarRadius;
     AvatarRow: typeof AvatarRow;
     AvatarGrid: typeof AvatarGrid;
@@ -346,7 +330,6 @@
 EmptyState.Description = Description;
 EmptyState.Illustration = Illustration;
 EmptyState.FeaturedIcon = FeaturedIcon;
-EmptyState.FileTypeIcon = FileTypeIcon;
 EmptyState.AvatarRadius = AvatarRadius;
 EmptyState.AvatarRow = AvatarRow;
 EmptyState.AvatarGrid = AvatarGrid;
```

### base_progress-indicators_progress-indicators.patch
```diff
--- a/src/components/base/progress-indicators/progress-indicators.tsx
+++ b/src/components/base/progress-indicators/progress-indicators.tsx
@@ -28,17 +28,20 @@
      * It receives the raw value and the calculated percentage.
      */
     valueFormatter?: (value: number, valueInPercentage: number) => string | number;
+    /** mdp patch (QC N13): accessible name for the progressbar. */
+    "aria-label"?: string;
 }
 
 /**
  * A basic progress bar component.
  */
-export const ProgressBarBase = ({ value, min = 0, max = 100, className, progressClassName }: ProgressBarProps) => {
+export const ProgressBarBase = ({ value, min = 0, max = 100, className, progressClassName, "aria-label": ariaLabel }: ProgressBarProps) => {
     const percentage = ((value - min) * 100) / (max - min);
 
     return (
         <div
             role="progressbar"
+            aria-label={ariaLabel}
             aria-valuenow={value}
             aria-valuemin={min}
             aria-valuemax={max}
```

### shared-assets_background-patterns_index.patch
```diff
--- a/src/components/shared-assets/background-patterns/index.tsx
+++ b/src/components/shared-assets/background-patterns/index.tsx
@@ -1,15 +1,10 @@
+// mdp patch (QC N3): only the 'circle' pattern is bundled.
 import type { SVGProps } from "react";
 import { cx } from "@/utils/cx";
 import { Circle } from "./circle";
-import { Grid } from "./grid";
-import { GridCheck } from "./grid-check";
-import { Square } from "./square";
 
 const patterns = {
     circle: Circle,
-    square: Square,
-    grid: Grid,
-    "grid-check": GridCheck,
 };
 
 export interface BackgroundPatternProps extends Omit<SVGProps<SVGSVGElement>, "size"> {
```

### shared-assets_illustrations_index.patch
```diff
--- a/src/components/shared-assets/illustrations/index.tsx
+++ b/src/components/shared-assets/illustrations/index.tsx
@@ -1,14 +1,9 @@
+// mdp patch (QC N3): only the 'box' illustration is bundled.
 import type { HTMLAttributes } from "react";
 import { BoxIllustration } from "./box";
-import { CloudIllustration } from "./cloud";
-import { CreditCardIllustration } from "./credit-card";
-import { DocumentsIllustration } from "./documents";
 
 const types = {
     box: BoxIllustration,
-    cloud: CloudIllustration,
-    documents: DocumentsIllustration,
-    "credit-card": CreditCardIllustration,
 };
 
 export interface IllustrationProps extends HTMLAttributes<HTMLDivElement> {
```

## Excepción aprobada: `sonner` (P1F-M4)
Aprobada por Senior Developer el 2026-10-16. `sonner` se acepta como motor de toasts porque el propio Untitled UI lo declara como dependencia. El contenido de cada toast tiene que construirse con componentes de Untitled UI (FeaturedIcon, Button). Un toast con markup propio, o cualquier otra librería de toasts, sigue contando como fallo.
Motivo: los componentes Notifications/Alerts de Untitled UI son PRO y no se imitan (aprobado también por Designer, §9.2/§9.3). Versión fijada exacta `sonner@2.0.8`; uso en `web/src/toasts.tsx`; sin parches.
