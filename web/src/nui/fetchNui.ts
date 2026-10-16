import type { NuiCallbacks, NuiEvent, NuiResponse } from '@/types';
import { isInGame, resourceName } from './env';

export const NUI_TIMEOUT_MS = 10_000;

/** POST to RegisterNUICallback(event). 10 s timeout → {ok:false, error:'timeout'}. Browser dev → mocks. */
export async function fetchNui<E extends NuiEvent>(event: E, data: NuiCallbacks[E]['req']): Promise<NuiResponse<NuiCallbacks[E]['res']>>;
export async function fetchNui<T = unknown>(event: string, data?: unknown): Promise<NuiResponse<T>>;
export async function fetchNui(event: string, data: unknown = {}): Promise<NuiResponse> {
  if (!isInGame) {
    if (import.meta.env.DEV) {
      const { mockNui } = await import('@/dev/mock');
      return mockNui(event, data);
    }
    return { ok: false, error: 'server_error' };
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), NUI_TIMEOUT_MS);
  try {
    const resp = await fetch(`https://${resourceName}/${event}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data),
      signal: ctrl.signal,
    });
    if (!resp.ok) return { ok: false, error: 'server_error' };
    const json = (await resp.json()) as NuiResponse;
    return json && typeof json.ok === 'boolean' ? json : { ok: false, error: 'server_error' };
  } catch (e) {
    return { ok: false, error: (e as Error)?.name === 'AbortError' ? 'timeout' : 'server_error' };
  } finally {
    clearTimeout(timer);
  }
}
