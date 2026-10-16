import type { NuiCallbacks, NuiEvent, NuiResponse } from '@/types';
import { isInGame, resourceName } from './env';
import { mockNui } from '@/dev/mock';

/** POST to RegisterNUICallback(event). Browser mode → mock responses. */
export async function fetchNui<E extends NuiEvent>(event: E, data: NuiCallbacks[E]['req']): Promise<NuiResponse<NuiCallbacks[E]['res']>>;
export async function fetchNui<T = unknown>(event: string, data?: unknown): Promise<NuiResponse<T>>;
export async function fetchNui(event: string, data: unknown = {}): Promise<NuiResponse> {
  if (!isInGame) {
    const res = await mockNui(event, data);
    console.debug('[nui:mock]', event, data, '→', res);
    return res;
  }
  try {
    const resp = await fetch(`https://${resourceName}/${event}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data),
    });
    return (await resp.json()) as NuiResponse;
  } catch {
    return { ok: false, error: 'server_error' };
  }
}
