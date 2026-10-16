import type { ReactNode } from 'react';
import { Car01 } from '@untitledui/icons';
import { EmptyState } from '@/components/application/empty-state/empty-state';

/** Untitled UI EmptyState (design-system §4.6: Featured icon gray + Car01). */
export function Empty({ title, description, footer }: { title: string; description?: string; footer?: ReactNode }) {
  return (
    <EmptyState size="md" className="py-10">
      <EmptyState.Header pattern="circle">
        <EmptyState.FeaturedIcon icon={Car01} color="gray" />
      </EmptyState.Header>
      <EmptyState.Content>
        <EmptyState.Title>{title}</EmptyState.Title>
        {description ? <EmptyState.Description>{description}</EmptyState.Description> : null}
      </EmptyState.Content>
      {footer ? <EmptyState.Footer>{footer}</EmptyState.Footer> : null}
    </EmptyState>
  );
}
