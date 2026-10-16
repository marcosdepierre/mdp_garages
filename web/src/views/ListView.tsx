// PLACEHOLDER — final screen pending design.
import { Button } from '@/components/base/buttons/button';
import { Badge } from '@/components/base/badges/badges';
import type { OpenData, Vehicle } from '@/types';
import { VehicleState } from '@/types';
import type { Router } from '@/router';

const stateLabel: Record<VehicleState, [string, 'gray' | 'success' | 'warning' | 'error']> = {
  [VehicleState.Out]: ['Out', 'warning'],
  [VehicleState.Garaged]: ['Garaged', 'success'],
  [VehicleState.ParkedWorld]: ['Parked', 'gray'],
  [VehicleState.Impounded]: ['Impounded', 'error'],
  [VehicleState.Retired]: ['Retired', 'gray'],
};

function Row({ v, router }: { v: Vehicle; router: Router }) {
  const [label, color] = stateLabel[v.state];
  const retired = v.state === VehicleState.Retired;
  return (
    <div className="flex items-center justify-between rounded-lg border border-secondary bg-secondary p-3">
      <span className="text-primary">{v.label} <span className="font-mono text-tertiary">[{v.plate}]</span></span>
      <div className="flex items-center gap-2">
        <Badge type="pill-color" color={color} size="sm">{label}</Badge>
        {/* Retired (state 4): cannot be taken out here — recovered from the phone app (phase 7). */}
        {!retired && <Button size="sm" color="secondary" onClick={() => router.navigate('detail', { plate: v.plate })}>Details</Button>}
      </div>
    </div>
  );
}

export function ListView({ data, router }: { data: OpenData; router: Router }) {
  const active = data.vehicles.filter((v) => v.state !== VehicleState.Retired);
  const retired = data.vehicles.filter((v) => v.state === VehicleState.Retired);
  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm text-tertiary">List view (placeholder) — {active.length} vehicles</p>
      {active.map((v) => <Row key={v.plate} v={v} router={router} />)}
      {retired.length > 0 && (
        <section className="mt-4 flex flex-col gap-3">
          <h2 className="font-display text-lg font-semibold uppercase text-secondary">Retirados</h2>
          {retired.map((v) => <Row key={v.plate} v={v} router={router} />)}
        </section>
      )}
    </div>
  );
}
