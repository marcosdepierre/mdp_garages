// Placeholder-level detail (phase 0), per wireframe: title + state, plate line, stat bars, primary action.
import { useState } from 'react';
import { CornerDownLeft } from '@untitledui/icons';
import { Badge, BadgeWithDot } from '@/components/base/badges/badges';
import { Button } from '@/components/base/buttons/button';
import { ProgressBarBase } from '@/components/base/progress-indicators/progress-indicators';
import { errorKey, useT } from '@/i18n';
import { fetchNui } from '@/nui/fetchNui';
import { stateMeta } from '@/state';
import type { NuiErrorCode, OpenData } from '@/types';
import { VehicleState, isValidPlate, normalizeError } from '@/types';
import { cx } from '@/utils/cx';
import { Empty } from './Empty';
import { clampPct, statColor } from './stats';

export function DetailView({ data, plate, onTakenOut }: { data: OpenData; plate?: string; onTakenOut: () => void }) {
  const t = useT();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<NuiErrorCode | undefined>();
  const v = plate && isValidPlate(plate) ? data.vehicles?.find((x) => x.plate === plate) : undefined;

  if (!v) return <Empty title={t('select_vehicle')} />;

  const meta = stateMeta(v.state);
  const garageId = data.garage?.id;
  // N6: no garage in 'open' → cannot take out. Take-out allowed for state 1 (garaged) and 2 (parked_world,
  // server safety net). 3 impounded = display only (paid release phase 5); 4 retired never reaches here.
  const st = Number(v.state);
  const canTakeOut = !!garageId && (st === VehicleState.Garaged || st === VehicleState.ParkedWorld) && isValidPlate(v.plate);

  const takeOut = async () => {
    if (!canTakeOut || !garageId) return;
    setBusy(true); setError(undefined);
    const res = await fetchNui('takeOut', { plate: v.plate, garage_id: garageId });
    setBusy(false);
    if (res.ok) onTakenOut();
    else setError(res.error === undefined ? 'server_error' : normalizeError(res.error));
  };

  const stats = [
    { key: 'engine', n: clampPct(v.engine, 10) },
    { key: 'body', n: clampPct(v.body, 10) },
    { key: 'fuel', n: clampPct(v.fuel) },
  ];

  return (
    <div className="flex h-full flex-col gap-6">
      <div className="flex flex-col gap-2">
        <div className="flex items-center gap-3">
          <h2 className="truncate font-display text-display-md font-bold uppercase text-primary">{v.label}</h2>
          <BadgeWithDot type="pill-color" size="md" color={meta.color}>{t(meta.key)}</BadgeWithDot>
        </div>
        <p className="text-sm text-tertiary">
          {t('plate')} <span className="font-mono text-secondary">{v.plate}</span>
          {' · '}{t(v.is_owner ? 'owner' : 'key_holder')}
          {' · '}{t('mileage')} {Math.round(Number(v.mileage) || 0)} {v.mileage_unit}
        </p>
      </div>

      <div className="grid grid-cols-3 gap-4">
        {stats.map(({ key, n }) => (
          <div key={key} className="flex flex-col gap-1.5">
            <div className="flex justify-between">
              <span className="text-xs font-semibold uppercase tracking-wider text-tertiary">{t(key)}</span>
              <span className={cx('font-mono text-sm', n < 30 ? 'text-error-primary' : 'text-primary')}>{n}%</span>
            </div>
            <ProgressBarBase value={n} progressClassName={statColor(n)} className="h-2 transition-[width] duration-500" />
          </div>
        ))}
      </div>

      {/* Alerts are PRO → error shown with a FREE Badge. */}
      {error ? <Badge type="pill-color" size="lg" color="error">{t(errorKey(error))}</Badge> : null}

      <div className="mt-auto flex gap-3">
        <Button color="primary" size="lg" className="flex-1" iconTrailing={CornerDownLeft} isLoading={busy} isDisabled={!canTakeOut} onClick={takeOut}>
          {t('take_out')}
        </Button>
      </div>
    </div>
  );
}
