import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Button } from '@/components/base/buttons/button';
import { Dialog, Modal, ModalOverlay } from '@/components/application/modals/modal';
import { TableCard } from '@/components/application/table/table';
import { I18nContext, makeT } from '@/i18n';
import { fetchNui } from '@/nui/fetchNui';
import { isInGame } from '@/nui/env';
import { useNuiMessages } from '@/nui/useNuiMessages';
import { useRouter } from '@/router';
import { PANEL_H, PANEL_W, useAppScale } from '@/scale';
import type { LocaleTable, OpenData } from '@/types';
import { DetailView } from '@/views/DetailView';
import { ListView } from '@/views/ListView';

// Dev-only: tree-shaken out of production builds.
const DevToolbar = import.meta.env.DEV ? lazy(() => import('@/dev/DevToolbar')) : null;

export default function App() {
  const [visible, setVisible] = useState(false);
  const [data, setData] = useState<OpenData | null>(null);
  const [locale, setLocale] = useState<LocaleTable | undefined>();
  const router = useRouter();
  const scale = useAppScale();
  const t = useMemo(() => makeT(locale), [locale]);
  const closing = useRef(false);

  const hide = useCallback(() => { closing.current = false; setVisible(false); }, []);

  /** Contract: NUI only POSTs 'close'; Lua releases focus and replies → hide on the response. */
  const requestClose = useCallback(async () => {
    if (closing.current) return;
    closing.current = true;
    await fetchNui('close', {});
    hide(); // ok, error or timeout: never leave a stuck panel
  }, [hide]);

  useNuiMessages({
    open: (m) => {
      if (m.locale) setLocale(m.locale);
      setData({ garage: m.data?.garage, vehicles: Array.isArray(m.data?.vehicles) ? m.data.vehicles : [] });
      router.reset(m.view ?? 'list', m.plate ? { plate: m.plate } : undefined);
      closing.current = false;
      setVisible(true);
    },
    update: (m) => {
      // Ignore updates before the first 'open' (QC M1).
      setData((d) => {
        if (!d) { console.warn('[nui] update before open ignored'); return d; }
        return { ...d, ...m.data };
      });
      if (m.view) router.reset(m.view, m.plate ? { plate: m.plate } : undefined);
    },
    close: hide,
  });

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || !visible) return;
      e.preventDefault();
      if (e.type === 'keyup') void requestClose();
    };
    window.addEventListener('keydown', onKey, true);
    window.addEventListener('keyup', onKey, true);
    return () => { window.removeEventListener('keydown', onKey, true); window.removeEventListener('keyup', onKey, true); };
  }, [visible, requestClose]);

  useEffect(() => {
    if (import.meta.env.DEV && !isInGame) {
      void import('@/dev/mock').then(({ mockOpenMessage }) => window.postMessage(mockOpenMessage(), '*'));
    }
  }, []);

  const route = router.route;
  const title = data?.garage?.label ?? t('title');

  return (
    <I18nContext.Provider value={t}>
      <ModalOverlay isOpen={visible && !!data} isDismissable={false} isKeyboardDismissDisabled className="bg-transparent backdrop-blur-none p-0 sm:p-0">
        <Modal
          className="shrink-0 overflow-hidden bg-primary shadow-2xl ring-1 ring-secondary max-h-none sm:rounded-2xl"
          style={{ width: PANEL_W, height: PANEL_H, transform: `scale(${scale})` }}
        >
          <Dialog aria-label={title} className="flex h-full flex-col">
            <TableCard.Root className="flex h-full flex-col rounded-none shadow-none ring-0">
              <TableCard.Header
                title={title}
                className="font-display uppercase"
                contentTrailing={<Button size="sm" color="tertiary" onClick={() => void requestClose()}>{t('close')}</Button>}
              />
              <div className="flex-1 overflow-auto p-6">
                {data && route.name === 'list' && <ListView data={data} router={router} />}
                {data && route.name === 'detail' && (
                  <DetailView data={data} router={router} plate={route.params?.plate as string | undefined} onTakenOut={hide} />
                )}
              </div>
            </TableCard.Root>
          </Dialog>
        </Modal>
      </ModalOverlay>
      {DevToolbar && !isInGame && <Suspense fallback={null}><DevToolbar /></Suspense>}
    </I18nContext.Provider>
  );
}
