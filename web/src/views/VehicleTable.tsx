// Untitled UI Table of vehicles (cells styled per design-system §4.2: name, plate chip, state badge, stat bars).
import { Badge, BadgeWithDot } from '@/components/base/badges/badges';
import { ProgressBarBase } from '@/components/base/progress-indicators/progress-indicators';
import { Table } from '@/components/application/table/table';
import { useT } from '@/i18n';
import { stateMeta } from '@/state';
import type { Vehicle } from '@/types';
import { clampPct, statColor } from './stats';

export function VehicleTable({ label, vehicles, selected, onSelect }: {
  label: string; vehicles: Vehicle[]; selected?: string; onSelect?: (v: Vehicle) => void;
}) {
  const t = useT();
  return (
    <Table
      aria-label={label}
      size="sm"
      // N16: single click selects AND opens detail (onSelectionChange); Enter/Space select too.
      // Controlled selectedKeys keep the row highlighted. Retired table: no onSelect → selectionMode 'none'.
      selectionMode={onSelect ? 'single' : 'none'}
      selectionBehavior="replace"
      disallowEmptySelection
      selectedKeys={selected ? [selected] : []}
      onSelectionChange={onSelect ? (keys) => {
        if (keys === 'all') return;
        const key = [...keys][0];
        const v = vehicles.find((x) => x.plate === key);
        if (v) onSelect(v);
      } : undefined}
    >
      <Table.Header>
        <Table.Head id="label" isRowHeader label={t('model')} />
        <Table.Head id="plate" label={t('plate')} />
        <Table.Head id="stats" label={`${t('engine')} / ${t('body')} / ${t('fuel')}`} />
      </Table.Header>
      <Table.Body items={vehicles}>
        {(v) => {
          const meta = stateMeta(v.state);
          const bars = [
            { key: 'engine', n: clampPct(v.engine, 10) },
            { key: 'body', n: clampPct(v.body, 10) },
            { key: 'fuel', n: clampPct(v.fuel) },
          ];
          return (
            <Table.Row id={v.plate} className={onSelect ? 'cursor-pointer' : undefined}>
              <Table.Cell>
                <div className="flex flex-col gap-1">
                  <span className="truncate font-display text-lg font-semibold text-primary">{v.label}</span>
                  <BadgeWithDot type="pill-color" size="sm" color={meta.color}>{t(meta.key)}</BadgeWithDot>
                </div>
              </Table.Cell>
              <Table.Cell>
                <Badge type="modern" size="sm" color="gray" className="font-mono font-bold tracking-widest">{v.plate}</Badge>
              </Table.Cell>
              <Table.Cell>
                <div className="grid w-28 grid-cols-3 gap-1">
                  {bars.map(({ key, n }) => <ProgressBarBase key={key} aria-label={`${t(key)} ${n}%`} value={n} progressClassName={statColor(n)} className="h-1" />)}
                </div>
              </Table.Cell>
            </Table.Row>
          );
        }}
      </Table.Body>
    </Table>
  );
}
