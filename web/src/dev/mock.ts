// Browser/dev-mode mock data. Shapes = docs/architecture.md NUI contract.
import type { Garage, NuiResponse, OpenData, Vehicle } from '@/types';
import { VehicleState, isValidPlate } from '@/types';

export const garages: Garage[] = [
  { id: 'public:legion', kind: 'public', label: 'Legion Square Garage' },
  { id: 'private:12', kind: 'private', label: 'Vinewood Hills Garage', slots: 6, used: 2 },
  { id: 'impound:lspd', kind: 'impound', label: 'LSPD Impound', fee: 500 },
];

const now = Math.floor(Date.now() / 1000);
export const vehicles: Vehicle[] = [
  { plate: 'MDP001', model: 'sultan', label: 'Karin Sultan', state: VehicleState.Garaged, fuel: 82, engine: 1000, body: 980, mileage: 1520.4, mileage_unit: 'km', garage_id: 'public:legion', is_owner: true },
  { plate: 'MDP002', model: 'adder', label: 'Truffade Adder', state: VehicleState.Out, fuel: 40, engine: 750, body: 600, mileage: 8803, mileage_unit: 'km', garage_id: null, is_owner: true, coords: { x: 215.8, y: -810.1, z: 30.7 } },
  { plate: 'KEY 42', model: 'bati', label: 'Pegassi Bati 801', state: VehicleState.Garaged, fuel: 100, engine: 1000, body: 1000, mileage: 120, mileage_unit: 'km', garage_id: 'public:legion', is_owner: false },
  { plate: 'LS 8X 88', model: 'blista', label: 'Dinka Blista', state: VehicleState.ParkedWorld, fuel: 55, engine: 900, body: 870, mileage: 302, mileage_unit: 'km', garage_id: null, is_owner: true, coords: { x: -45.2, y: -1100.3, z: 26.4 } },
  { plate: 'MDP005', model: 'futo', label: 'Karin Futo', state: VehicleState.Impounded, fuel: 15, engine: 420, body: 300, mileage: 40110, mileage_unit: 'km', garage_id: 'impound:lspd', is_owner: true, impound: { reason: 'Illegal parking', fee: 500, release_after: now + 1800 } },
  { plate: 'OLD 77', model: 'emperor', label: 'Albany Emperor', state: VehicleState.Retired, fuel: 30, engine: 800, body: 750, mileage: 65230, mileage_unit: 'km', garage_id: null, is_owner: true },
];

export const vehiclesFor = (garageId: string) =>
  garageId.startsWith('impound:') ? vehicles.filter((v) => v.state === VehicleState.Impounded) : vehicles.filter((v) => v.state !== VehicleState.Impounded);

export const mockOpen = (garage: Garage = garages[0]): OpenData => ({ garage, vehicles: vehiclesFor(garage.id) });

export async function mockNui(event: string, data: unknown): Promise<NuiResponse> {
  await new Promise((r) => setTimeout(r, 250));
  const d = (data ?? {}) as Record<string, string>;
  switch (event) {
    case 'close': return { ok: true };
    case 'getVehicles':
      if (!garages.some((g) => g.id === d.garage_id)) return { ok: false, error: 'invalid_garage' };
      return { ok: true, data: vehiclesFor(d.garage_id) };
    case 'takeOut': {
      if (!isValidPlate(d.plate ?? '')) return { ok: false, error: 'invalid_request' };
      const v = vehicles.find((x) => x.plate === d.plate);
      if (!v) return { ok: false, error: 'not_owner' };
      if (v.state === VehicleState.Retired) return { ok: false, error: 'invalid_request' };
      if (v.state !== VehicleState.Garaged) return { ok: false, error: 'already_out' };
      return { ok: true, data: { netId: 1000 + Math.floor(Math.random() * 9000) } };
    }
    default: return { ok: false, error: 'invalid_request' };
  }
}
