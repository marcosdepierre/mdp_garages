import { Badge } from '@/components/base/badges/badges';
import { Button } from '@/components/base/buttons/button';
import { Table } from '@/components/application/table/table';
import { useT } from '@/i18n';
import { stateMeta } from '@/state';
import type { Vehicle } from '@/types';

/** Untitled UI Table of vehicles. `onDetails` omitted → no action column (retired). */
export function VehicleTable({ label, vehicles, onDetails }: { label: string; vehicles: Vehicle[]; onDetails?: (v: Vehicle) => void }) {
  const t = useT();
  return (
    <Table aria-label={label} size="sm">
      <Table.Header>
        <Table.Head id="label" isRowHeader label={t('model')} />
        <Table.Head id="plate" label={t('plate')} />
        <Table.Head id="state" label="" />
        {onDetails ? <Table.Head id="actions" label="" /> : null}
      </Table.Header>
      <Table.Body items={vehicles}>
        {(v) => {
          const meta = stateMeta(v.state);
          return (
            <Table.Row id={v.plate}>
              <Table.Cell className="font-display text-lg font-semibold text-primary">{v.label}</Table.Cell>
              <Table.Cell className="font-mono">{v.plate}</Table.Cell>
              <Table.Cell><Badge type="pill-color" size="sm" color={meta.color}>{t(meta.key)}</Badge></Table.Cell>
              {onDetails ? (
                <Table.Cell className="text-right">
                  <Button size="sm" color="secondary" onClick={() => onDetails(v)}>{t('details')}</Button>
                </Table.Cell>
              ) : null}
            </Table.Row>
          );
        }}
      </Table.Body>
    </Table>
  );
}
