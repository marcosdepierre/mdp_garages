import { useEffect, useRef } from 'react';
import type { NuiMessage } from '@/types';

type Handlers = { [A in NuiMessage['action']]?: (msg: Extract<NuiMessage, { action: A }>) => void };

/** Subscribes to window 'message' (SendNUIMessage) and dispatches by action. */
export function useNuiMessages(handlers: Handlers) {
  const ref = useRef(handlers);
  ref.current = handlers;
  useEffect(() => {
    const onMsg = (e: MessageEvent) => {
      const msg = e.data as NuiMessage | undefined;
      if (!msg || typeof msg.action !== 'string') return;
      const fn = ref.current[msg.action] as ((m: NuiMessage) => void) | undefined;
      if (fn) fn(msg); else console.warn('[nui] unhandled action', msg.action);
    };
    window.addEventListener('message', onMsg);
    return () => window.removeEventListener('message', onMsg);
  }, []);
}

/** Simulate a Lua message (dev). */
export const emitNui = (msg: NuiMessage) => window.postMessage(msg, '*');
