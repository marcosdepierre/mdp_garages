import type { ReactNode } from 'react';
import { EmptyState } from '@/components/application/empty-state/empty-state';

/** Untitled UI Empty state with a local (bundled SVG) illustration — no remote images. */
export function Empty({ title, description, footer }: { title: string; description?: string; footer?: ReactNode }) {
  return (
    <EmptyState size="md" className="py-10">
      <EmptyState.Header pattern="none">
        <EmptyState.Illustration type="box" />
      </EmptyState.Header>
      <EmptyState.Content>
        <EmptyState.Title>{title}</EmptyState.Title>
        {description ? <EmptyState.Description>{description}</EmptyState.Description> : null}
      </EmptyState.Content>
      {footer ? <EmptyState.Footer>{footer}</EmptyState.Footer> : null}
    </EmptyState>
  );
}
