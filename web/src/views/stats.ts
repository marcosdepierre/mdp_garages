/** design-system §4.3: >=60 green, 30-59 amber, <30 red. */
export const statColor = (n: number) => (n >= 60 ? 'bg-fg-success-primary' : n >= 30 ? 'bg-fg-warning-primary' : 'bg-fg-error-primary');
export const clampPct = (n: unknown, div = 1) => Math.max(0, Math.min(100, Math.round((Number(n) || 0) / div)));
