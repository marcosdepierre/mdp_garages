import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Button } from '@/components/base/buttons/button';
import { Dialog, Modal, ModalOverlay } from '@/components/application/modals/modal';
import { XClose } from '@untitledui/icons';
import { I18nContext, makeT } from '@/i18n';
import { fetchNui } from '@/nui/fetchNui';
import { isInGame } from '@/nui/env';
import { useNuiMessages } from '@/nui/useNuiMessages';
import { useRouter } from '@/router';
import { PANEL_H, PANEL_W, useAppScale } from '@/scale';
import type { LocaleTable, OpenData } from '@/types';
import { DetailView } from '@/views/DetailView';
import { ListView } from '@/views/ListView';
import { Empty } from '@/views/Empty';

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
  const vehicleCount = data?.vehicles?.length ?? 0;
  const selectedPlate = route.name === 'detail' ? (route.params?.plate as string | undefined) : undefined;

  return (
    <I18nContext.Provider value={t}>
      <ModalOverlay isOpen={visible && !!data} isDismissable={false} isKeyboardDismissDisabled className="bg-transparent backdrop-blur-none p-0 sm:p-0">
        <Modal
          className="shrink-0 overflow-hidden bg-primary shadow-2xl ring-1 ring-secondary max-h-none sm:rounded-2xl"
          style={{ width: PANEL_W, height: PANEL_H, transform: `scale(${scale})` }}
        >
          <Dialog aria-label={title} className="flex h-full flex-col">
            <header className="flex items-start justify-between px-8 pt-6 pb-4">
              <div className="flex flex-col gap-1">
                <h1 className="font-display text-display-sm font-bold uppercase text-primary">{title}</h1>
                <p className="text-sm text-tertiary">{vehicleCount} · {t('vehicles')}</p>
              </div>
              <Button size="md" color="secondary" iconLeading={XClose} aria-label={t('close')} onClick={() => void requestClose()} />
            </header>
            <div className="grid min-h-0 flex-1 grid-cols-[440px_1fr] gap-6 px-8 pb-8">
              <div className="min-h-0 overflow-auto pr-1">
                {data && <ListView data={data} router={router} selected={selectedPlate} />}
              </div>
              <div className="min-h-0 overflow-auto rounded-xl border border-secondary bg-secondary p-6">
                {data && (route.name === 'detail'
                  ? <DetailView data={data} plate={selectedPlate} onTakenOut={hide} />
                  : <Empty title={t('select_vehicle')} />)}
              </div>
            </div>
          </Dialog>
        </Modal>
      </ModalOverlay>
      {DevToolbar && !isInGame && <Suspense fallback={null}><DevToolbar /></Suspense>}
    </I18nContext.Provider>
  );
}
