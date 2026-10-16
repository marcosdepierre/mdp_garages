// PLACEHOLDER-level list (phase 0). Untitled UI: TableCard, Table, Badge, Button, Empty state.
import { TableCard } from '@/components/application/table/table';
import { useT } from '@/i18n';
import type { Router } from '@/router';
import type { OpenData } from '@/types';
import { VehicleState } from '@/types';
import { Empty } from './Empty';
import { VehicleTable } from './VehicleTable';

export function ListView({ data, router }: { data: OpenData; router: Router }) {
  const t = useT();
  const vehicles = Array.isArray(data.vehicles) ? data.vehicles : [];
  const active = vehicles.filter((v) => Number(v.state) !== VehicleState.Retired);
  const retired = vehicles.filter((v) => Number(v.state) === VehicleState.Retired);

  if (vehicles.length === 0) return <Empty title={t('empty')} />;

  return (
    <div className="flex flex-col gap-6">
      <TableCard.Root size="sm">
        <TableCard.Header title={t('vehicles')} badge={String(active.length)} />
        {active.length > 0
          ? <VehicleTable label={t('vehicles')} vehicles={active} onDetails={(v) => router.navigate('detail', { plate: v.plate })} />
          : <Empty title={t('empty')} />}
      </TableCard.Root>
      {retired.length > 0 && (
        // Retired (state 4): no take-out/details; recovered from the phone app (phase 7).
        <TableCard.Root size="sm">
          <TableCard.Header title={t('retired_section')} badge={String(retired.length)} description={t('retired_hint')} />
          <VehicleTable label={t('retired_section')} vehicles={retired} />
        </TableCard.Root>
      )}
    </div>
  );
}
