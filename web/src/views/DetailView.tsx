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
import { VehicleState, isValidPlate, normalizeError, visibleVehicles } from '@/types';
import { Table, TableCard } from '@/components/application/table/table';
import { cx } from '@/utils/cx';
import { Empty } from './Empty';
import { clampPct, statColor } from './stats';

export function DetailView({ data, plate, onTakenOut }: { data: OpenData; plate?: string; onTakenOut: () => void }) {
  const t = useT();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<NuiErrorCode | undefined>();
  const v = plate && isValidPlate(plate) ? visibleVehicles(data.vehicles).find((x) => x.plate === plate) : undefined;

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

  const rows = [
    { id: 'plate', k: t('plate'), node: <span className="font-mono text-primary">{v.plate}</span> },
    { id: 'owner', k: t('owner'), node: <BadgeWithDot type="pill-color" size="sm" color={v.is_owner ? 'brand' : 'gray'}>{t(v.is_owner ? 'owner' : 'key_holder')}</BadgeWithDot> },
    { id: 'mileage', k: t('mileage'), node: <span className="font-mono text-primary">{`${Math.round(Number(v.mileage) || 0)} ${v.mileage_unit}`}</span> },
  ];

  return (
    <TableCard.Root size="sm" className="flex h-full flex-col">
      <TableCard.Header
        title={v.label}
        className="[&_h2]:font-display [&_h2]:text-display-xs [&_h2]:font-bold [&_h2]:uppercase"
        badge={<BadgeWithDot type="pill-color" size="md" color={meta.color}>{t(meta.key)}</BadgeWithDot>}
      />
      <div className="grid grid-cols-3 gap-4 px-4 py-5">
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
      <Table aria-label={v.label} size="sm">
        <Table.Header className="sr-only">
          <Table.Head id="k" isRowHeader label={t('details')} />
          <Table.Head id="v" label={t('details')} />
        </Table.Header>
        <Table.Body items={rows}>
          {(r) => (
            <Table.Row id={r.id}>
              <Table.Cell className="text-tertiary">{r.k}</Table.Cell>
              <Table.Cell>{r.node}</Table.Cell>
            </Table.Row>
          )}
        </Table.Body>
      </Table>
      {/* Alerts are PRO → error shown with a FREE Badge. */}
      {error ? <div className="px-4 pt-4"><Badge type="pill-color" size="lg" color="error">{t(errorKey(error))}</Badge></div> : null}
      <div className="mt-auto flex gap-3 p-4">
        <Button color="primary" size="lg" className="flex-1" iconTrailing={CornerDownLeft} isLoading={busy} isDisabled={!canTakeOut} onClick={takeOut}>
          {t('take_out')}
        </Button>
      </div>
    </TableCard.Root>
  );
}
