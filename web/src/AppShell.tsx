import { useEffect, useState, type ReactNode } from 'react';

const BASE_W = 1920, BASE_H = 1080;
export const PANEL_W = 1180, PANEL_H = 680;

/** --app-scale = min(innerWidth/1920, innerHeight/1080); panel is fixed 1180x680 at base resolution. */
function useAppScale() {
  const calc = () => Math.min(window.innerWidth / BASE_W, window.innerHeight / BASE_H);
  const [scale, setScale] = useState(calc);
  useEffect(() => {
    const on = () => setScale(calc());
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);
  return scale;
}

export function AppShell({ children }: { children: ReactNode }) {
  const scale = useAppScale();
  return (
    <div className="fixed inset-0 flex items-center justify-center" style={{ ['--app-scale' as string]: scale }}>
      <div
        className="flex shrink-0 flex-col overflow-hidden rounded-2xl bg-primary shadow-2xl ring-1 ring-secondary animate-in fade-in zoom-in-95 duration-300 ease-out motion-reduce:animate-none"
        style={{ width: PANEL_W, height: PANEL_H, transform: `scale(${scale})` }}
      >
        {children}
      </div>
    </div>
  );
}
