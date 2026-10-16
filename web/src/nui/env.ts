declare global { interface Window { GetParentResourceName?: () => string; invokeNative?: unknown } }
export const isInGame = typeof window.GetParentResourceName === 'function' || typeof window.invokeNative !== 'undefined';
export const resourceName = window.GetParentResourceName?.() ?? 'mdp_garages';
