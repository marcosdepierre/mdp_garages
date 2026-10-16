// List (phase 1): Untitled UI TableCard + Table; "Retired" = TableCard header (Section header is PRO), §10.3.
import { Archive } from '@untitledui/icons';
import { TableCard } from '@/components/application/table/table';
import { Button } from '@/components/base/buttons/button';
import { FeaturedIcon } from '@/components/foundations/featured-icon/featured-icon';
import { useT } from '@/i18n';
import type { Router } from '@/router';
import type { Vehicle } from '@/types';
import { VehicleState } from '@/types';
import { Empty } from './Empty';
import { VehicleTable } from './VehicleTable';

export function ListView({ vehicles, router, selected, locked, onClose }: {
  vehicles: Vehicle[]; router: Router; selected?: string; locked?: boolean; onClose: () => void;
}) {
  const t = useT();
  const active = vehicles.filter((v) => Number(v.state) !== VehicleState.Retired);
  const retired = vehicles.filter((v) => Number(v.state) === VehicleState.Retired);

  if (vehicles.length === 0)
    return <Empty title={t('empty')} description={t('empty_hint')} footer={<Button size="md" color="secondary" onClick={onClose}>{t('close')}</Button>} />;

  const select = (plate: string) =>
    router.route.name === 'detail' ? router.reset('detail', { plate }) : router.navigate('detail', { plate });

  return (
    <div className="flex flex-col gap-4">
      <TableCard.Root size="sm">
        <TableCard.Header title={t('vehicles')} badge={String(active.length)} />
        {active.length > 0
          ? <VehicleTable label={t('vehicles')} vehicles={active} selected={selected} locked={locked} onSelect={(v) => select(v.plate)} />
          : <Empty title={t('empty')} />}
      </TableCard.Root>
      {retired.length > 0 && (
        // Retired (state 4): read-only, not selectable; recovered from the phone app (phase 7).
        <TableCard.Root size="sm">
          <TableCard.Header title={t('retired_section')} badge={String(retired.length)}
            contentTrailing={<span className="flex items-center gap-2 text-sm text-tertiary"><FeaturedIcon icon={Archive} color="gray" theme="light" size="sm" />{t('retired_hint')}</span>} />
          <VehicleTable label={t('retired_section')} vehicles={retired} dimmed />
        </TableCard.Root>
      )}
    </div>
  );
}
