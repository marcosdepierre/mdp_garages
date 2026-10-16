// design-system §9.3: sonner + Untitled UI FeaturedIcon ("Notifications" is PRO → not used).
import type { FC } from 'react';
import { Toaster, toast } from 'sonner';
import { AlertCircle, AlertTriangle, CheckCircle, InfoCircle, XClose } from '@untitledui/icons';
import { LoadingIndicator } from '@/components/application/loading-indicator/loading-indicator';
import { Button } from '@/components/base/buttons/button';
import { FeaturedIcon } from '@/components/foundations/featured-icon/featured-icon';
import type { ToastKind } from '@/types';

const META: Record<ToastKind, { color: 'success' | 'error' | 'warning' | 'brand'; icon: FC<{ className?: string }>; duration: number }> = {
  success: { color: 'success', icon: CheckCircle, duration: 4000 },
  error: { color: 'error', icon: AlertCircle, duration: 6000 },
  warning: { color: 'warning', icon: AlertTriangle, duration: 5000 },
  info: { color: 'brand', icon: InfoCircle, duration: 4000 },
  loading: { color: 'brand', icon: InfoCircle, duration: Infinity },
};

export interface ToastInput { id?: string; kind: ToastKind; title: string; description?: string; closeLabel: string }

export function showToast({ id, kind, title, description, closeLabel }: ToastInput) {
  const m = META[kind];
  return toast.custom((tid) => (
    <div role={kind === 'error' ? 'alert' : 'status'} className="flex w-85 items-start gap-3 rounded-xl bg-secondary p-4 shadow-lg ring-1 ring-secondary">
      {kind === 'loading'
        ? <div className="flex size-8 items-center justify-center"><LoadingIndicator type="line-spinner" size="sm" /></div>
        : <FeaturedIcon icon={m.icon} color={m.color} theme="dark" size="sm" />}
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <p className="text-sm font-semibold text-primary">{title}</p>
        {description ? <p className="text-sm text-tertiary">{description}</p> : null}
      </div>
      {/* CloseButton is not offered by the CLI (0.1.69) → Untitled UI Button tertiary icon-only */}
      {kind !== 'loading' ? <Button size="sm" color="tertiary" iconLeading={XClose} aria-label={closeLabel} onClick={() => toast.dismiss(tid)} /> : null}
    </div>
  ), { id, duration: m.duration });
}

/** Mounted outside the scaled panel; scales itself with --app-scale from the top-right corner. */
export function ToastLayer({ scale }: { scale: number }) {
  return (
    <div data-react-aria-top-layer="true" className="pointer-events-none fixed top-0 right-0 z-[90] [color-scheme:dark] *:pointer-events-auto"
      style={{ transform: `scale(${scale})`, transformOrigin: 'top right' }}>
      <Toaster position="top-right" theme="dark" visibleToasts={3} offset={24} toastOptions={{ unstyled: true }} />
    </div>
  );
}
