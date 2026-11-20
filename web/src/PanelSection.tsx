// A side-panel section whose heading collapses it, like Scene JSON. On phones
// the panel sits below the canvas, so folding sections away saves scrolling.
// Each section's open state is remembered in this browser.
import {useState, type ReactNode} from 'react';
import {Collapsible} from '@astryxdesign/core/Collapsible';
import {VStack} from '@astryxdesign/core/Layout';
import {Section} from '@astryxdesign/core/Section';
import {Heading} from '@astryxdesign/core/Text';

const KEY = 'fringe.panel.';

function load(id: string): boolean | null {
  try {
    const v = localStorage.getItem(KEY + id);
    return v === null ? null : v === '1';
  } catch {
    return null;
  }
}

function save(id: string, open: boolean) {
  try {
    localStorage.setItem(KEY + id, open ? '1' : '0');
  } catch {
    // Storage blocked (private mode): the section just doesn't remember.
  }
}

interface Props {
  /** Stable id for remembering the open state. */
  id: string;
  title: ReactNode;
  /** Shown beside the title, inside the toggle (no buttons: the trigger is itself a button). */
  aside?: ReactNode;
  /** Open state before the viewer has toggled it. */
  defaultIsOpen?: boolean;
  /** Gap between the content's children, in Astryx spacing steps. */
  gap?: 2 | 3 | 4;
  children: ReactNode;
}

export function PanelSection({id, title, aside, defaultIsOpen = true, gap = 4, children}: Props) {
  const [isOpen, setIsOpen] = useState(() => load(id) ?? defaultIsOpen);
  return (
    <Section variant="transparent" padding={4}>
      <Collapsible
        trigger={
          <span className="panel-section-trigger">
            <Heading level={3}>{title}</Heading>
            {aside}
          </span>
        }
        isOpen={isOpen}
        onOpenChange={(open) => {
          setIsOpen(open);
          save(id, open);
        }}
      >
        <VStack gap={gap} style={{paddingTop: 16}}>
          {children}
        </VStack>
      </Collapsible>
    </Section>
  );
}
