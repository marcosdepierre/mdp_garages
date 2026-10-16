import { useCallback, useState } from 'react';
import type { ViewName } from '@/types';

export interface Route { name: ViewName; params?: Record<string, unknown> }

/** Minimal state-based router: navigate / back / reset. */
export function useRouter(initial: Route = { name: 'list' }) {
  const [stack, setStack] = useState<Route[]>([initial]);
  const navigate = useCallback((name: ViewName, params?: Route['params']) => setStack((s) => [...s, { name, params }]), []);
  const back = useCallback(() => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s)), []);
  const reset = useCallback((name: ViewName, params?: Route['params']) => setStack([{ name, params }]), []);
  return { route: stack[stack.length - 1], canGoBack: stack.length > 1, navigate, back, reset };
}
export type Router = ReturnType<typeof useRouter>;
