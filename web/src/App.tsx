import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AlertCircle, XClose } from '@untitledui/icons';
import { LoadingIndicator } from '@/components/application/loading-indicator/loading-indicator';
import { Dialog, Modal, ModalOverlay } from '@/components/application/modals/modal';
import { TableCard } from '@/components/application/table/table';
import { Button } from '@/components/base/buttons/button';
import { I18nContext, LangContext, errorKey, langTag, makeT } from '@/i18n';
import { fetchNui } from '@/nui/fetchNui';
import { isInGame } from '@/nui/env';
import { useNuiMessages } from '@/nui/useNuiMessages';
import { useRouter } from '@/router';
import { PANEL_H, PANEL_W, useAppScale } from '@/scale';
import { ToastLayer, showToast } from '@/toasts';
import type { Garage, LocaleTable, NuiErrorCode, Vehicle } from '@/types';
import { VehicleState, normalizeError, visibleVehicles } from '@/types';
import { DetailView } from '@/views/DetailView';
import { Empty } from '@/views/Empty';
import { ListView } from '@/views/ListView';

// Dev-only: tree-shaken out of production builds.
const DevToolbar = import.meta.env.DEV ? lazy(() => import('@/dev/DevToolbar')) : null;

type Load = { status: 'ready' } | { status: 'loading' } | { status: 'error'; code: NuiErrorCode };

export default function App() {
  const [visible, setVisible] = useState(false);
  const [garage, setGarage] = useState<Garage | undefined>();
  const [vehicles, setVehicles] = useState<Vehicle[] | null>(null); // null = never opened
  const [load, setLoad] = useState<Load>({ status: 'ready' });
  const [busy, setBusy] = useState(false); // §9.1 take-out in flight → lock rows, close, ESC
  const [locale, setLocale] = useState<LocaleTable | undefined>();
  const [lang, setLang] = useState<string>('en-US');
  const router = useRouter();
  const scale = useAppScale();
  const t = useMemo(() => makeT(locale), [locale]);
  const closing = useRef(false);
  const loadSeq = useRef(0);

  const hide = useCallback(() => { closing.current = false; setBusy(false); setVisible(false); }, []);

  /** Contract: NUI only POSTs 'close'; Lua releases focus and replies → hide on the response. */
  const requestClose = useCallback(async () => {
    if (closing.current || busy) return; // §9.1: ESC/close ignored while loading
    closing.current = true;
    await fetchNui('close', {});
    hide();
  }, [hide, busy]);

  /** Phase 1: 'open' without vehicles → fetch through the NUI callback. */
  const fetchVehicles = useCallback(async (g?: Garage) => {
    if (!g?.id) return;
    const seq = ++loadSeq.current;
    setLoad({ status: 'loading' });
    const res = await fetchNui('getVehicles', { garage_id: g.id });
    if (seq !== loadSeq.current) return; // stale
    if (res.ok && Array.isArray(res.data)) { setVehicles(res.data); setLoad({ status: 'ready' }); }
    else setLoad({ status: 'error', code: res.error === undefined ? 'server_error' : normalizeError(res.error) });
  }, []);

  useNuiMessages({
    open: (m) => {
      if (m.locale) setLocale(m.locale);
      if (m.lang) setLang(langTag(m.lang));
      setGarage(m.data?.garage);
      router.reset(m.view ?? 'list', m.plate ? { plate: m.plate } : undefined);
      closing.current = false;
      setBusy(false);
      if (Array.isArray(m.data?.vehicles)) { loadSeq.current++; setVehicles(m.data.vehicles); setLoad({ status: 'ready' }); }
      else { setVehicles([]); void fetchVehicles(m.data?.garage); }
      setVisible(true);
    },
    update: (m) => {
      if (vehicles === null) { console.warn('[nui] update before open ignored'); return; } // QC M1
      if (m.data?.garage) setGarage(m.data.garage);
      if (Array.isArray(m.data?.vehicles)) { loadSeq.current++; setVehicles(m.data.vehicles); setLoad({ status: 'ready' }); }
      if (m.view) router.reset(m.view, m.plate ? { plate: m.plate } : undefined);
    },
    close: hide,
    toast: (m) => {
      // Lua-driven feedback (store/park), works with the panel closed and without NUI focus.
      if (m.locale) setLocale(m.locale);
      if (m.lang) setLang(langTag(m.lang));
      const tt = makeT(m.locale ?? locale);
      const title = m.title ?? (m.titleKey ? tt(m.titleKey) : m.error ? tt(errorKey(m.error)) : tt('error'));
      const description = m.description ?? ((m.title || m.titleKey) && m.error ? tt(errorKey(m.error)) : undefined);
      showToast({ id: m.id, kind: m.kind, title, description, closeLabel: tt('close') });
    },
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
      // Dev: ?view=detail&plate=MDP001 opens the detail directly; ?fetch=1 opens without vehicles (loading path).
      const q = new URLSearchParams(location.search);
      void import('@/dev/mock').then(({ mockOpenMessage, garages }) => {
        const g = garages.find((x) => x.id === q.get('garage')) ?? garages[0];
        const msg = mockOpenMessage(g, q.get('view') === 'detail' ? 'detail' : 'list', q.get('plate') ?? undefined);
        if (q.get('fetch') && msg.action === 'open') delete (msg.data as { vehicles?: unknown }).vehicles;
        window.postMessage(msg, '*');
      });
    }
  }, []);

  const route = router.route;
  const title = garage?.label ?? t('title');
  const list = visibleVehicles(vehicles); // state 5 never rendered
  const vehicleCount = list.filter((v) => Number(v.state) !== VehicleState.Retired).length; // N12
  const selectedPlate = route.name === 'detail' ? (route.params?.plate as string | undefined) : undefined;
  const closePanel = () => void requestClose();

  return (
    <LangContext.Provider value={lang}>
      <I18nContext.Provider value={t}>
        <ModalOverlay isOpen={visible && vehicles !== null} isDismissable={false} isKeyboardDismissDisabled className="bg-transparent backdrop-blur-none p-0 sm:p-0">
          <Modal
            className={`shrink-0 overflow-hidden [color-scheme:dark] bg-primary shadow-2xl ring-1 ring-secondary max-h-none sm:rounded-2xl ${busy ? 'cursor-progress' : ''}`}
            style={{ width: PANEL_W, height: PANEL_H, transform: `scale(${scale})` }}
          >
            <Dialog aria-label={title} className="flex h-full flex-col">
              <div data-testid="panel" aria-busy={busy || load.status === 'loading'} className="flex h-full flex-col">
              <header className="flex items-start justify-between px-8 pt-6 pb-4">
                <div className="flex flex-col gap-1">
                  <h1 className="font-display text-display-sm font-bold uppercase text-primary">{title}</h1>
                  <p className="text-sm text-tertiary">{vehicleCount} · {t('vehicles')}</p>
                </div>
                <Button size="md" color="secondary" iconLeading={XClose} aria-label={t('close')} isDisabled={busy} onClick={closePanel} />
              </header>
              {load.status === 'loading' ? (
                <div className="flex flex-1 items-center justify-center"><LoadingIndicator type="line-spinner" size="md" label={t('loading')} /></div>
              ) : load.status === 'error' ? (
                <div className="flex flex-1 items-center justify-center">
                  <Empty icon={AlertCircle} color="error" title={t('error')} description={t(errorKey(load.code))}
                    footer={<>
                      <Button size="md" color="primary" onClick={() => void fetchVehicles(garage)}>{t('retry')}</Button>
                      <Button size="md" color="secondary" onClick={closePanel}>{t('close')}</Button>
                    </>} />
                </div>
              ) : (
                <div className="grid min-h-0 flex-1 grid-cols-[520px_1fr] gap-6 px-8 pb-8">
                  <div className="min-h-0 overflow-auto pr-1">
                    <ListView vehicles={list} router={router} selected={selectedPlate} locked={busy} onClose={closePanel} />
                  </div>
                  <div className="min-h-0 overflow-auto">
                    {route.name === 'detail'
                      ? <DetailView garage={garage} vehicles={list} plate={selectedPlate} onBusyChange={setBusy} onTakenOut={hide} />
                      : <TableCard.Root size="sm" className="h-full"><Empty title={t('select_vehicle')} /></TableCard.Root>}
                  </div>
                </div>
              )}
              </div>
            </Dialog>
          </Modal>
        </ModalOverlay>
        <ToastLayer scale={scale} />
        {DevToolbar && !isInGame && <Suspense fallback={null}><DevToolbar /></Suspense>}
      </I18nContext.Provider>
    </LangContext.Provider>
  );
}
