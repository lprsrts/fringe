// Chapter-grouped browser for all 20 bundled puzzles, with local star progress
// and direct jump into any puzzle (including Half adder, XOR, and Dark spot).
import {Badge} from '@astryxdesign/core/Badge';
import {Button} from '@astryxdesign/core/Button';
import {Icon} from '@astryxdesign/core/Icon';
import {HStack, VStack} from '@astryxdesign/core/Layout';
import {Heading, Text} from '@astryxdesign/core/Text';
import {StarIcon as StarOutline} from '@heroicons/react/24/outline';
import {StarIcon as StarSolid} from '@heroicons/react/20/solid';

import type {PuzzleSummary} from './solver';
import {CHAPTERS, type ProgressMap} from './puzzle';

interface Props {
  puzzles: PuzzleSummary[];
  progress: ProgressMap;
  onOpen: (id: string, loadReference?: boolean) => void;
}

const GOAL_BADGE: Record<string, string> = {
  truth_table: 'Logic',
  maximize: 'Maximize',
  minimize: 'Minimize',
  target: 'Split',
};

export function PuzzleBrowser({puzzles, progress, onOpen}: Props) {
  const solvedCount = puzzles.filter((p) => (progress[p.id]?.stars ?? 0) > 0).length;
  const totalStars = puzzles.reduce((s, p) => s + (progress[p.id]?.stars ?? 0), 0);

  return (
    <div className="puzzle-browser">
      <VStack gap={6}>
        <HStack gap={4} vAlign="center" hAlign="between" style={{flexWrap: 'wrap'}}>
          <VStack gap={1}>
            <Heading level={2}>Puzzles</Heading>
            <Text type="supporting">
              Place optical parts to steer light, cancel waves and build logic gates. Every check runs a full Maxwell solve in your browser.
            </Text>
          </VStack>
          <HStack gap={2} vAlign="center">
            <Badge variant={solvedCount > 0 ? 'success' : 'neutral'} label={`${solvedCount} / ${puzzles.length} solved`} />
            <Badge variant="yellow" label={`${totalStars} / ${puzzles.length * 3} stars`} />
          </HStack>
        </HStack>

        <div className="featured-banner">
          <HStack gap={4} vAlign="center" hAlign="between" style={{flexWrap: 'wrap'}}>
            <VStack gap={1} style={{flex: 1, minWidth: 'min(240px, 100%)'}}>
              <Text type="label" weight="semibold">
                Featured · Addition with light
              </Text>
              <Text type="supporting">
                Build a 1-bit binary half adder (0+0=00, 1+0=01, 0+1=01, 1+1=10) from a single slab of glass, or open the working solution and toggle inputs A and B.
              </Text>
            </VStack>
            <HStack gap={2} style={{flexWrap: 'wrap'}}>
              <Button label="Try working half adder" variant="primary" size="sm" onClick={() => onOpen('logic-half-adder', true)} />
              <Button label="Solve from scratch" variant="secondary" size="sm" onClick={() => onOpen('logic-half-adder', false)} />
            </HStack>
          </HStack>
        </div>

        {CHAPTERS.map((chapter) => {
          const items = puzzles.filter((p) => p.chapter === chapter.id);
          if (items.length === 0) return null;
          const chapterSolved = items.filter((p) => (progress[p.id]?.stars ?? 0) > 0).length;
          return (
            <VStack key={chapter.id} gap={3}>
              <HStack gap={3} vAlign="start" hAlign="between">
                <VStack gap={0} style={{minWidth: 0}}>
                  <Heading level={3}>{chapter.title}</Heading>
                  <Text type="supporting">{chapter.subtitle}</Text>
                </VStack>
                <span className="chapter-count">
                  <Text type="supporting" hasTabularNumbers>
                    {chapterSolved} / {items.length}
                  </Text>
                </span>
              </HStack>
              <div className="puzzle-grid">
                {items.map((p) => {
                  const stars = progress[p.id]?.stars ?? 0;
                  return (
                    <button
                      key={p.id}
                      type="button"
                      className={`puzzle-card${stars > 0 ? ' puzzle-card-solved' : ''}`}
                      onClick={() => onOpen(p.id, false)}
                    >
                      <div className="puzzle-card-head">
                        <span className="puzzle-card-title">{p.title}</span>
                        <span className="puzzle-stars" aria-label={`${stars} of 3 stars`}>
                          {[1, 2, 3].map((n) => (
                            <Icon
                              key={n}
                              icon={n <= stars ? StarSolid : StarOutline}
                              size="xsm"
                              color={n <= stars ? 'warning' : 'secondary'}
                            />
                          ))}
                        </span>
                      </div>
                      <p className="puzzle-card-summary">{p.summary}</p>
                      <div className="puzzle-card-foot">
                        <Badge variant="neutral" label={GOAL_BADGE[p.goal_type] ?? p.goal_type} />
                      </div>
                    </button>
                  );
                })}
              </div>
            </VStack>
          );
        })}
      </VStack>
    </div>
  );
}
