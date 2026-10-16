import type { FC, ReactNode } from 'react';
import { Car01 } from '@untitledui/icons';
import { FeaturedIcon } from '@/components/foundations/featured-icon/featured-icon';

/** Empty state per design-system §4.6: Featured icon (gray, Car01) + title/description + optional action.
 *  Text styles copied from UUI EmptyState (size md); EmptyState itself is not imported (QC N3: it pulls
 *  @untitledui/file-icons + all illustrations/patterns statically). */
export function Empty({ title, description, footer, icon = Car01 }: { title: string; description?: string; footer?: ReactNode; icon?: FC<{ className?: string }> }) {
  return (
    <div className="flex flex-col items-center py-10 text-center">
      <FeaturedIcon icon={icon} color="gray" theme="modern" size="lg" className="mb-5" />
      <div className="mb-6 flex flex-col items-center gap-2">
        <h2 className="text-lg font-semibold text-primary">{title}</h2>
        {description ? <p className="text-sm text-tertiary">{description}</p> : null}
      </div>
      {footer ? <footer className="flex gap-3">{footer}</footer> : null}
    </div>
  );
}
