import type { FC, ReactNode } from 'react';
import { Car01 } from '@untitledui/icons';
import { EmptyState } from '@/components/application/empty-state/empty-state';

/** Untitled UI EmptyState (design-system §11): size md, circle pattern, FeaturedIcon (gray by default). */
export function Empty({ title, description, footer, icon = Car01, color = 'gray' }: {
  title: string; description?: string; footer?: ReactNode; icon?: FC<{ className?: string }>; color?: 'gray' | 'error';
}) {
  return (
    <EmptyState size="md" className="py-10">
      <EmptyState.Header pattern="circle">
        <EmptyState.FeaturedIcon icon={icon} color={color} />
      </EmptyState.Header>
      <EmptyState.Content>
        <EmptyState.Title>{title}</EmptyState.Title>
        {description ? <EmptyState.Description>{description}</EmptyState.Description> : null}
      </EmptyState.Content>
      {footer ? <EmptyState.Footer>{footer}</EmptyState.Footer> : null}
    </EmptyState>
  );
}
