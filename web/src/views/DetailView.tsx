// PLACEHOLDER-level detail (phase 0). Untitled UI: TableCard, Table, ProgressBar, Badge, Button, Empty state.
import { useState } from 'react';
import { Badge } from '@/components/base/badges/badges';
import { Button } from '@/components/base/buttons/button';
import { ProgressBar } from '@/components/base/progress-indicators/progress-indicators';
import { Table, TableCard } from '@/components/application/table/table';
import { errorKey, useT } from '@/i18n';
import { fetchNui } from '@/nui/fetchNui';
import type { Router } from '@/router';
import { stateMeta } from '@/state';
import type { NuiErrorCode, OpenData } from '@/types';
import { VehicleState, isValidPlate } from '@/types';
import { Empty } from './Empty';

const pct = (v: number) => `${Math.round(v)}%`;

export function DetailView({ data, router, plate, onTakenOut }: { data: OpenData; router: Router; plate?: string; onTakenOut: () => void }) {
  const t = useT();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<NuiErrorCode | undefined>();
  // No silent fallback to vehicles[0] (QC B1): unknown/missing plate → empty state.
  const v = plate && isValidPlate(plate) ? data.vehicles?.find((x) => x.plate === plate) : undefined;
  const backBtn = <Button size="sm" color="secondary" onClick={router.back} isDisabled={!router.canGoBack}>{t('back')}</Button>;

  if (!v) return <Empty title={t('select_vehicle')} footer={router.canGoBack ? backBtn : undefined} />;

  const meta = stateMeta(v.state);
  const canTakeOut = Number(v.state) === VehicleState.Garaged && isValidPlate(v.plate);

  const takeOut = async () => {
    if (!canTakeOut) return;
    setBusy(true); setError(undefined);
    const res = await fetchNui('takeOut', { plate: v.plate, garage_id: data.garage.id });
    setBusy(false);
    if (res.ok) onTakenOut(); // Lua UI.Close() also sends 'close' on success
    else setError(res.error ?? 'server_error');
  };

  const rows = [
    { id: 'plate', k: t('plate'), node: <span className="font-mono">{v.plate}</span> },
    { id: 'owner', k: t('owner'), node: <Badge type="pill-color" size="sm" color={v.is_owner ? 'brand' : 'gray'}>{t(v.is_owner ? 'owner' : 'key_holder')}</Badge> },
    { id: 'fuel', k: t('fuel'), node: <ProgressBar value={v.fuel} labelPosition="right" valueFormatter={pct} /> },
    { id: 'engine', k: t('engine'), node: <ProgressBar value={v.engine / 10} labelPosition="right" valueFormatter={pct} /> },
    { id: 'body', k: t('body'), node: <ProgressBar value={v.body / 10} labelPosition="right" valueFormatter={pct} /> },
    { id: 'mileage', k: t('mileage'), node: <span>{`${Math.round(v.mileage)} ${v.mileage_unit}`}</span> },
  ];

  return (
    <TableCard.Root size="sm">
      <TableCard.Header
        title={v.label}
        badge={<Badge type="pill-color" size="sm" color={meta.color}>{t(meta.key)}</Badge>}
        contentTrailing={<div className="flex gap-2">{backBtn}
          <Button size="sm" isLoading={busy} isDisabled={!canTakeOut} onClick={takeOut}>{t('take_out')}</Button></div>}
      />
      {/* Alert is PRO in Untitled UI → error shown with a FREE Badge. */}
      {error ? <div className="px-4 pt-3"><Badge type="pill-color" size="md" color="error">{t(errorKey(error))}</Badge></div> : null}
      <Table aria-label={v.label} size="sm">
        <Table.Header>
          <Table.Head id="k" isRowHeader label="" />
          <Table.Head id="v" label="" />
        </Table.Header>
        <Table.Body items={rows}>
          {(r) => (
            <Table.Row id={r.id}>
              <Table.Cell>{r.k}</Table.Cell>
              <Table.Cell>{r.node}</Table.Cell>
            </Table.Row>
          )}
        </Table.Body>
      </Table>
    </TableCard.Root>
  );
}
