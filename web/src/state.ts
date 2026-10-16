import type { BadgeColors } from '@/components/base/badges/badge-types';
import { VehicleState } from '@/types';

type Meta = { key: string; color: BadgeColors };
// Exhaustive over VehicleState (Removed is never rendered but typed for completeness).
const META: Record<VehicleState, Meta> = {
  [VehicleState.Out]: { key: 'state_out', color: 'warning' },
  [VehicleState.Garaged]: { key: 'state_garaged', color: 'success' },
  [VehicleState.ParkedWorld]: { key: 'state_parked', color: 'gray' },
  [VehicleState.Impounded]: { key: 'state_impounded', color: 'error' },
  [VehicleState.Retired]: { key: 'state_retired', color: 'gray' },
  [VehicleState.Removed]: { key: 'state_unknown', color: 'gray' },
};
/** Unknown / malformed states get a generic gray badge instead of crashing. */
export const stateMeta = (state: unknown): Meta => META[Number(state) as VehicleState] ?? { key: 'state_unknown', color: 'gray' };
