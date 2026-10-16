// DEV ONLY (excluded from production via import.meta.env.DEV). Exempt from the UUI-only rule per QC.
import { Button } from '@/components/base/buttons/button';
import { emitNui } from '@/nui/useNuiMessages';
import { garages, mockOpenMessage, vehicles } from './mock';

export default function DevToolbar() {
  return (
    <div data-react-aria-top-layer="true" className="fixed bottom-2 left-2 z-[100] flex items-center gap-2 rounded-lg bg-primary/90 p-2 ring-1 ring-secondary">
      {garages.map((g) => (
        <Button key={g.id} size="xs" color="secondary" onClick={() => emitNui(mockOpenMessage(g))}>open {g.kind}</Button>
      ))}
      <Button size="xs" color="secondary" onClick={() => emitNui(mockOpenMessage(garages[0], 'detail', vehicles[0].plate))}>detail</Button>
      <Button size="xs" color="secondary" onClick={() => emitNui(mockOpenMessage(garages[0], 'detail'))}>detail (no plate)</Button>
      <Button size="xs" color="secondary" onClick={() => emitNui({ action: 'update', data: { vehicles: vehicles.slice(0, 2) } })}>update</Button>
      <Button size="xs" color="secondary" onClick={() => emitNui({ action: 'update', data: { vehicles: [{ ...vehicles[0], plate: 'BAD 9', state: 9 as never }] } })}>unknown state</Button>
      <Button size="xs" color="secondary" onClick={() => emitNui({ action: 'update', data: { vehicles: [] } })}>empty</Button>
      <Button size="xs" color="secondary" onClick={() => { emitNui({ action: 'toast', id: 'store', kind: 'loading', titleKey: 'storing', description: 'Karin Sultan · MDP001' }); setTimeout(() => emitNui({ action: 'toast', id: 'store', kind: 'success', title: 'Vehicle stored', description: 'Karin Sultan · MDP001' }), 1200); }}>store ok</Button>
      <Button size="xs" color="secondary" onClick={() => emitNui({ action: 'toast', id: 'store', kind: 'error', error: 'occupied' })}>store err</Button>
      <Button size="xs" color="secondary" onClick={() => emitNui({ action: 'open', view: 'list', data: { garage: garages[0] } })}>open (fetch)</Button>
      <Button size="xs" color="secondary-destructive" onClick={() => emitNui({ action: 'close' })}>close</Button>
    </div>
  );
}
