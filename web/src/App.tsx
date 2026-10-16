import { useCallback, useEffect, useState } from 'react';
import { Button } from '@/components/base/buttons/button';
import type { OpenData } from '@/types';
import { fetchNui } from '@/nui/fetchNui';
import { isInGame } from '@/nui/env';
import { useNuiMessages } from '@/nui/useNuiMessages';
import { useRouter } from '@/router';
import { ListView } from '@/views/ListView';
import { DetailView } from '@/views/DetailView';
import { AppShell } from '@/AppShell';
import { DevToolbar } from '@/dev/DevToolbar';
import { mockOpen } from '@/dev/mock';

export default function App() {
  const [visible, setVisible] = useState(false);
  const [data, setData] = useState<OpenData | null>(null);
  const router = useRouter();

  const hide = useCallback(() => setVisible(false), []);
  /** User-initiated close → tell Lua to drop focus. */
  const requestClose = useCallback(() => { setVisible(false); void fetchNui('close', {}); }, []);

  useNuiMessages({
    open: (m) => { setData(m.data); router.reset(m.view ?? 'list'); setVisible(true); },
    update: (m) => { setData((d) => (d ? { ...d, ...m.data } : (m.data as OpenData))); if (m.view) router.reset(m.view); },
    close: hide,
  });

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && visible) requestClose(); };
    window.addEventListener('keyup', onKey);
    return () => window.removeEventListener('keyup', onKey);
  }, [visible, requestClose]);

  useEffect(() => {
    if (!isInGame) { setData(mockOpen()); setVisible(true); }
  }, []);

  return (
    <>
      {visible && data && (
        <AppShell>
            <header className="flex items-center justify-between border-b border-secondary px-6 py-4">
              <h1 className="font-display text-display-sm font-bold uppercase text-primary">{data.garage.label}</h1>
              <Button size="sm" color="tertiary" onClick={requestClose}>Close</Button>
            </header>
            <main className="flex-1 overflow-auto p-6">
              {router.route.name === 'list' && <ListView data={data} router={router} />}
              {router.route.name === 'detail' && (
                <DetailView data={data} router={router} plate={router.route.params?.plate as string | undefined} onClosed={hide} />
              )}
            </main>
        </AppShell>
      )}
      {!isInGame && <DevToolbar />}
    </>
  );
}
