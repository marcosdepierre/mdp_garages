// PLACEHOLDER — final screen pending design.
import { Button } from '@/components/base/buttons/button';
import type { NuiErrorCode, OpenData } from '@/types';
import { VehicleState } from '@/types';
import { fetchNui } from '@/nui/fetchNui';
import type { Router } from '@/router';
import { useState } from 'react';

export function DetailView({ data, router, plate, onClosed }: { data: OpenData; router: Router; plate?: string; onClosed: () => void }) {
  const v = data.vehicles.find((x) => x.plate === plate) ?? data.vehicles[0];
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<NuiErrorCode | undefined>();
  if (!v) return <p className="text-tertiary">No vehicle</p>;

  const takeOut = async () => {
    setBusy(true); setError(undefined);
    const res = await fetchNui('takeOut', { plate: v.plate, garage_id: data.garage.id });
    setBusy(false);
    if (res.ok) onClosed(); // Lua also closes the UI on success
    else setError(res.error);
  };

  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm text-tertiary">Detail view (placeholder)</p>
      <pre className="overflow-auto rounded-lg bg-secondary p-3 text-xs text-secondary">{JSON.stringify(v, null, 2)}</pre>
      {error && <p className="text-sm text-error-primary">Error: {error}</p>}
      <div className="flex gap-2">
        <Button size="sm" color="secondary" onClick={router.back} isDisabled={!router.canGoBack}>Back</Button>
        <Button size="sm" isLoading={busy} isDisabled={v.state !== VehicleState.Garaged /* also blocks Retired */} onClick={takeOut}>Take out</Button>
      </div>
    </div>
  );
}
