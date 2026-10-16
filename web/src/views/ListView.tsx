// Placeholder-level list (phase 0): Untitled UI TableCard + Table; "Retired" = TableCard header (Section header is PRO).
import { TableCard } from '@/components/application/table/table';
import { useT } from '@/i18n';
import type { Router } from '@/router';
import type { OpenData } from '@/types';
import { VehicleState, visibleVehicles } from '@/types';
import { Empty } from './Empty';
import { VehicleTable } from './VehicleTable';

export function ListView({ data, router, selected }: { data: OpenData; router: Router; selected?: string }) {
  const t = useT();
  const vehicles = visibleVehicles(data.vehicles); // state 5 (Removed) never rendered
  const active = vehicles.filter((v) => Number(v.state) !== VehicleState.Retired);
  const retired = vehicles.filter((v) => Number(v.state) === VehicleState.Retired);

  if (vehicles.length === 0) return <Empty title={t('empty')} />;

  const select = (plate: string) =>
    router.route.name === 'detail' ? router.reset('detail', { plate }) : router.navigate('detail', { plate });

  return (
    <div className="flex flex-col gap-4">
      <TableCard.Root size="sm">
        <TableCard.Header title={t('vehicles')} badge={String(active.length)} />
        {active.length > 0
          ? <VehicleTable label={t('vehicles')} vehicles={active} selected={selected} onSelect={(v) => select(v.plate)} />
          : <Empty title={t('empty')} />}
      </TableCard.Root>
      {retired.length > 0 && (
        // Retired (state 4): not selectable, no take-out; recovered from the phone app (phase 7).
        <TableCard.Root size="sm">
          <TableCard.Header title={t('retired_section')} badge={String(retired.length)} description={t('retired_hint')} />
          <VehicleTable label={t('retired_section')} vehicles={retired} />
        </TableCard.Root>
      )}
    </div>
  );
}
