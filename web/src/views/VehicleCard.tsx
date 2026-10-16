// Vehicle card per design-system §4.2 ("div custom con tokens UUI" + Badge + Progress bar).
import { BadgeWithDot } from '@/components/base/badges/badges';
import { ProgressBarBase } from '@/components/base/progress-indicators/progress-indicators';
import { useT } from '@/i18n';
import { stateMeta } from '@/state';
import type { Vehicle } from '@/types';
import { VehicleState } from '@/types';
import { cx } from '@/utils/cx';
import { clampPct, statColor } from './stats';

export function VehicleCard({ v, selected, onSelect }: { v: Vehicle; selected?: boolean; onSelect?: () => void }) {
  const t = useT();
  const meta = stateMeta(v.state);
  const bars = [clampPct(v.engine, 10), clampPct(v.body, 10), clampPct(v.fuel)];
  return (
    <button
      type="button"
      aria-pressed={selected}
      disabled={!onSelect}
      onClick={onSelect}
      className={cx(
        'grid w-full grid-cols-[1fr_auto] gap-x-3 gap-y-2 rounded-xl border px-4 py-3 text-left outline-hidden transition duration-100 focus-visible:ring-4 focus-visible:ring-focus-ring/24',
        selected ? 'border-brand bg-tertiary shadow-lg ring-1 ring-brand' : 'border-secondary bg-secondary enabled:hover:bg-tertiary',
        Number(v.state) === VehicleState.Impounded && 'opacity-85',
        !onSelect && 'cursor-default',
      )}
    >
      <span className="truncate font-display text-xl font-semibold text-primary">{v.label}</span>
      <BadgeWithDot type="pill-color" size="sm" color={meta.color}>{t(meta.key)}</BadgeWithDot>
      <span className="col-span-2 flex items-center gap-2">
        <span className="rounded-md bg-[#E9EDF3] px-2 py-0.5 font-mono text-xs font-bold tracking-widest text-[#0A0A0A]">{v.plate}</span>
      </span>
      <span className="col-span-2 grid grid-cols-3 gap-2">
        {bars.map((n, i) => <ProgressBarBase key={i} value={n} progressClassName={statColor(n)} className="h-1" />)}
      </span>
    </button>
  );
}
