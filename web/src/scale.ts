import { useEffect, useState } from 'react';

export const BASE_W = 1920, BASE_H = 1080, PANEL_W = 1180, PANEL_H = 680;

/**
 * Scale from the 1920x1080 base, but never below 1 while the panel still fits (95% of viewport),
 * so 12px text (badges) never renders smaller than 12px down to ~1242x716. Below that, fit wins.
 */
export function computeScale(w = window.innerWidth, h = window.innerHeight) {
  const base = Math.min(w / BASE_W, h / BASE_H);
  const fit = Math.min((w * 0.95) / PANEL_W, (h * 0.95) / PANEL_H);
  return Math.max(base, Math.min(1, fit));
}

export function useAppScale() {
  const [scale, setScale] = useState(() => computeScale());
  useEffect(() => {
    const on = () => setScale(computeScale());
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);
  return scale;
}
