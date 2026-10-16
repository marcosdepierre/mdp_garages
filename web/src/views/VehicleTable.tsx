// Untitled UI Table of vehicles (cells styled per design-system §4.2: name, plate chip, state badge, stat bars).
import { BadgeWithDot } from '@/components/base/badges/badges';
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
      selectionMode={onSelect ? 'single' : 'none'}
      selectionBehavior="replace"
      selectedKeys={selected ? [selected] : []}
      onRowAction={onSelect ? (key) => { const v = vehicles.find((x) => x.plate === key); if (v) onSelect(v); } : undefined}
    >
      <Table.Header>
        <Table.Head id="label" isRowHeader label={t('model')} />
        <Table.Head id="plate" label={t('plate')} />
        <Table.Head id="stats" label={`${t('engine')} / ${t('body')} / ${t('fuel')}`} />
      </Table.Header>
      <Table.Body items={vehicles}>
        {(v) => {
          const meta = stateMeta(v.state);
          const bars = [clampPct(v.engine, 10), clampPct(v.body, 10), clampPct(v.fuel)];
          return (
            <Table.Row id={v.plate} className={onSelect ? 'cursor-pointer' : undefined}>
              <Table.Cell>
                <div className="flex flex-col gap-1">
                  <span className="truncate font-display text-lg font-semibold text-primary">{v.label}</span>
                  <BadgeWithDot type="pill-color" size="sm" color={meta.color}>{t(meta.key)}</BadgeWithDot>
                </div>
              </Table.Cell>
              <Table.Cell>
                <span className="rounded-md bg-[#E9EDF3] px-2 py-0.5 font-mono text-xs font-bold tracking-widest text-[#0A0A0A]">{v.plate}</span>
              </Table.Cell>
              <Table.Cell>
                <div className="grid w-28 grid-cols-3 gap-1">
                  {bars.map((n, i) => <ProgressBarBase key={i} value={n} progressClassName={statColor(n)} className="h-1" />)}
                </div>
              </Table.Cell>
            </Table.Row>
          );
        }}
      </Table.Body>
    </Table>
  );
}
