import { Button } from '@/components/base/buttons/button';
import { emitNui } from '@/nui/useNuiMessages';
import { garages, mockOpen, vehicles } from './mock';

/** Browser-only toolbar to simulate Lua messages. */
export function DevToolbar() {
  return (
    <div className="fixed bottom-2 left-2 z-50 flex items-center gap-2 rounded-lg bg-primary/90 p-2 ring-1 ring-secondary">
      <span className="text-xs font-semibold text-tertiary">DEV</span>
      {garages.map((g) => (
        <Button key={g.id} size="xs" color="secondary" onClick={() => emitNui({ action: 'open', view: 'list', data: mockOpen(g) })}>open {g.kind}</Button>
      ))}
      <Button size="xs" color="secondary" onClick={() => emitNui({ action: 'open', view: 'detail', data: mockOpen() })}>open detail</Button>
      <Button size="xs" color="secondary" onClick={() => emitNui({ action: 'update', data: { vehicles: vehicles.slice(0, 2) } })}>update</Button>
      <Button size="xs" color="secondary-destructive" onClick={() => emitNui({ action: 'close' })}>close</Button>
    </div>
  );
}
