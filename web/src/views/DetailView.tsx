// Detail sheet (design-system §8, §9.1, §9.4, §10). Untitled UI: TableCard, Table, ProgressBarBase, Badge(WithDot),
// Button, FeaturedIcon. Info/error blocks are custom (Alerts is PRO), per §9.4/§10.1.
import { useEffect, useState } from 'react';
import { AlertCircle, CornerDownLeft, RefreshCw01 } from '@untitledui/icons';
import { Table, TableCard } from '@/components/application/table/table';
import { Badge, BadgeWithDot } from '@/components/base/badges/badges';
import { Button } from '@/components/base/buttons/button';
import { ProgressBarBase } from '@/components/base/progress-indicators/progress-indicators';
import { FeaturedIcon } from '@/components/foundations/featured-icon/featured-icon';
import { RETRYABLE, fmtDateTime, fmtMileage, fmtMoney } from '@/format';
import { errorKey, useLang, useT } from '@/i18n';
import { fetchNui } from '@/nui/fetchNui';
import { stateMeta } from '@/state';
import { showToast } from '@/toasts';
import type { Garage, NuiErrorCode, Vehicle } from '@/types';
import { VehicleState, isValidPlate, normalizeError } from '@/types';
import { cx } from '@/utils/cx';
import { Empty } from './Empty';
import { clampPct, healthPct, statColor } from './stats';

export function DetailView({ garage, vehicles, plate, onBusyChange, onTakenOut }: {
  garage?: Garage; vehicles: Vehicle[]; plate?: string; onBusyChange: (busy: boolean) => void; onTakenOut: () => void;
}) {
  const t = useT();
  const lang = useLang();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<NuiErrorCode | undefined>();
  const v = plate && isValidPlate(plate) ? vehicles.find((x) => x.plate === plate) : undefined;

  useEffect(() => { setError(undefined); }, [plate]); // §9.4: cleared when switching vehicle
  useEffect(() => { onBusyChange(busy); }, [busy, onBusyChange]);

  if (!v) return <TableCard.Root size="sm" className="h-full"><Empty title={t('select_vehicle')} /></TableCard.Root>;

  const meta = stateMeta(v.state);
  const st = Number(v.state);
  const garageId = garage?.id;
  const impounded = st === VehicleState.Impounded;
  // N6 + contract: take-out for state 1 and 2 only; 3 impounded display-only (payment = phase 5); 4 never selectable.
  const canTakeOut = !!garageId && (st === VehicleState.Garaged || st === VehicleState.ParkedWorld) && isValidPlate(v.plate);
  const disabledReason = canTakeOut ? undefined
    : !garageId ? 'err_invalid_garage'
    : st === VehicleState.Out ? 'err_already_out'
    : st === VehicleState.Retired ? 'err_retired'
    : impounded ? undefined // explained by the impound block
    : 'err_invalid_state';

  const takeOut = async () => {
    if (!canTakeOut || !garageId || busy) return;
    setBusy(true); setError(undefined);
    const res = await fetchNui('takeOut', { plate: v.plate, garage_id: garageId });
    setBusy(false);
    if (res.ok) {
      // §9.1 success: toast + close. Never waits for props (applied by Integrations via 'mdp:props').
      showToast({ id: 'takeout', kind: 'success', title: t('taken_out'), description: `${v.label} · ${v.plate}`, closeLabel: t('close') });
      onTakenOut();
    } else {
      const code = res.error === undefined ? 'server_error' : normalizeError(res.error);
      setError(code);
      showToast({ id: 'takeout', kind: 'error', title: t(errorKey(code)), description: `${v.label} · ${v.plate}`, closeLabel: t('close') });
    }
  };

  const stats = [
    { key: 'engine', n: healthPct(v.engine) },
    { key: 'body', n: healthPct(v.body) },
    { key: 'fuel', n: clampPct(v.fuel) },
  ];
  const location = v.garage_id && v.garage_id === garage?.id ? garage.label
    : v.coords ? `${Math.round(v.coords.x)}, ${Math.round(v.coords.y)}` : undefined;
  const rows = [
    { id: 'plate', k: t('plate'), node: <Badge type="modern" size="sm" color="gray" className="font-mono font-bold tracking-widest">{v.plate}</Badge> },
    { id: 'owner', k: t('owner'), node: <BadgeWithDot type="pill-color" size="sm" color={v.is_owner ? 'brand' : 'gray'}>{t(v.is_owner ? 'owner' : 'key_holder')}</BadgeWithDot> },
    { id: 'mileage', k: t('mileage'), node: <span className="font-mono text-primary">{fmtMileage(lang, v.mileage, v.mileage_unit)}</span> },
    ...(location ? [{ id: 'location', k: t('location'), node: <span className="text-primary">{location}</span> }] : []),
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
            <ProgressBarBase aria-label={`${t(key)} ${n}%`} value={n} progressClassName={statColor(n)} className="h-2" />
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

      {impounded ? (
        // §10.1 impound info block. Payment modal/button = phase 5 (not built).
        <div role="note" className="mx-4 mt-4 flex items-start gap-3 rounded-xl bg-error-primary p-4 ring-1 ring-error_subtle">
          <FeaturedIcon icon={AlertCircle} color="error" theme="light" size="md" />
          <div className="flex flex-col gap-1 text-sm">
            <p className="font-semibold text-error-primary">{t('state_impounded')}</p>
            {v.impound?.reason ? <p className="text-secondary">{t('impound_reason')}: {v.impound.reason}</p> : null}
            <p className="text-secondary">
              {t('impound_fee')}: <span className="font-mono">{fmtMoney(lang, v.impound?.fee ?? garage?.fee)}</span>
              {' · '}{t('release_after')}: {v.impound?.release_after && v.impound.release_after * 1000 > Date.now()
                ? fmtDateTime(lang, v.impound.release_after) : t('available_now')}
            </p>
          </div>
        </div>
      ) : null}

      {error ? (
        // §9.4 inline error (Alerts is PRO → custom block) + Retry only for retryable codes.
        <div role="alert" className="mx-4 mt-4 flex items-start gap-3 rounded-xl bg-error-primary p-3 ring-1 ring-error_subtle">
          <FeaturedIcon icon={AlertCircle} color="error" theme="light" size="sm" />
          <p className="flex-1 text-sm text-error-primary">{t(errorKey(error))}</p>
          {RETRYABLE.has(error) ? <Button color="secondary" size="sm" iconLeading={RefreshCw01} isDisabled={busy} onClick={takeOut}>{t('retry')}</Button> : null}
        </div>
      ) : null}

      {!impounded ? (
        <div className="mt-auto flex flex-col gap-2 p-4">
          {disabledReason ? <p id="takeout-hint" className="text-sm text-tertiary">{t(disabledReason)}</p> : null}
          <Button aria-describedby={disabledReason ? 'takeout-hint' : undefined} color="primary" size="lg" className="flex-1"
            iconTrailing={CornerDownLeft} isLoading={busy} isDisabled={!canTakeOut} onClick={takeOut}>
            {t('take_out')}
          </Button>
        </div>
      ) : <div className="mt-auto p-4" />}
    </TableCard.Root>
  );
}
