// Placeholder-level list (phase 0): vehicle cards + separate "Retired" section.
import { useT } from '@/i18n';
import type { Router } from '@/router';
import type { OpenData } from '@/types';
import { VehicleState } from '@/types';
import { Empty } from './Empty';
import { VehicleCard } from './VehicleCard';

export function ListView({ data, router, selected }: { data: OpenData; router: Router; selected?: string }) {
  const t = useT();
  const vehicles = Array.isArray(data.vehicles) ? data.vehicles : [];
  const active = vehicles.filter((v) => Number(v.state) !== VehicleState.Retired);
  const retired = vehicles.filter((v) => Number(v.state) === VehicleState.Retired);

  if (vehicles.length === 0) return <Empty title={t('empty')} />;

  return (
    <div className="flex flex-col gap-2">
      {active.map((v) => (
        <VehicleCard key={v.plate} v={v} selected={v.plate === selected}
          onSelect={() => (router.route.name === 'detail' ? router.reset('detail', { plate: v.plate }) : router.navigate('detail', { plate: v.plate }))} />
      ))}
      {retired.length > 0 && (
        // Retired (state 4): not selectable, no take-out; recovered from the phone app (phase 7).
        <section className="mt-4 flex flex-col gap-2" aria-label={t('retired_section')}>
          <h2 className="font-display text-lg font-bold uppercase text-secondary">{t('retired_section')}</h2>
          <p className="text-sm text-tertiary">{t('retired_hint')}</p>
          {retired.map((v) => <VehicleCard key={v.plate} v={v} />)}
        </section>
      )}
    </div>
  );
}
