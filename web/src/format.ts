/** design-system §8.3: grouped integer mileage in the active locale; '—' when not numeric. */
export const fmtMileage = (lang: string, value: unknown, unit: string) => {
  const n = Number(value);
  if (value === null || value === undefined || value === '' || !Number.isFinite(n)) return '—';
  return `${new Intl.NumberFormat(lang, { maximumFractionDigits: 0, useGrouping: 'always' } as unknown as Intl.NumberFormatOptions).format(n)} ${unit}`;
};
/** Display-only money (server recomputes fees). */
export const fmtMoney = (lang: string, value: unknown) => {
  const n = Number(value);
  return Number.isFinite(n) ? `${new Intl.NumberFormat(lang, { maximumFractionDigits: 0, useGrouping: 'always' } as unknown as Intl.NumberFormatOptions).format(n)} $` : '—';
};
export const fmtDateTime = (lang: string, unixSeconds: number) =>
  new Intl.DateTimeFormat(lang, { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }).format(new Date(unixSeconds * 1000));

/** design-system §9.4: errors that show a Retry button. */
export const RETRYABLE = new Set(['timeout', 'server_error', 'rate_limited', 'no_spawn', 'spawn_failed', 'locked', 'in_use', 'vehicle_moved']);
