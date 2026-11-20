// Right panel in Puzzle mode: navigation, Goal card with star track & Check,
// parts palette, parts list, selected-part Inspector, progressive hints, and
// display settings.
import {useEffect, useState} from 'react';
import {Badge} from '@astryxdesign/core/Badge';
import {Button} from '@astryxdesign/core/Button';
import {Collapsible} from '@astryxdesign/core/Collapsible';
import {Divider} from '@astryxdesign/core/Divider';
import {Icon} from '@astryxdesign/core/Icon';
import {HStack, VStack} from '@astryxdesign/core/Layout';
import {Section} from '@astryxdesign/core/Section';
import {PanelSection} from './PanelSection';
import {SegmentedControl, SegmentedControlItem} from '@astryxdesign/core/SegmentedControl';
import {Selector} from '@astryxdesign/core/Selector';
import {Switch} from '@astryxdesign/core/Switch';
import {Heading, Text} from '@astryxdesign/core/Text';
import {
  ArrowPathIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  LightBulbIcon,
  LockClosedIcon,
  PlusIcon,
  SparklesIcon,
  Squares2X2Icon,
  StarIcon as StarOutline,
  TrashIcon,
} from '@heroicons/react/24/outline';
import {CheckCircleIcon, StarIcon as StarSolid, XCircleIcon} from '@heroicons/react/20/solid';

import type {MaterialPreset, Puzzle, PuzzleCheckReport, PuzzleEvaluation, PuzzleSummary} from './solver';
import {
  canAddPalettePart,
  enabledDesignCount,
  extractDesign,
  formatScore,
  formatThreshold,
  lockedIds,
  paletteEntryLabel,
  paletteUsage,
  puzzlePassLine,
  puzzleScoreScale,
  puzzleStarsLine,
  puzzleTaskLine,
  type PuzzleProgress,
} from './puzzle';
import {makeItem, sameItem, SHAPE_TITLES, titleOf, type Item, type Json, type Scene} from './scene';
import {Inspector} from './Inspector';

interface Props {
  puzzle: Puzzle;
  puzzles: PuzzleSummary[];
  progress: PuzzleProgress | undefined;
  scene: Scene;
  presets: MaterialPreset[];
  selected: Item | null;
  ruleCheck: PuzzleCheckReport | null;
  evaluation: PuzzleEvaluation | null;
  checkCurrent: boolean;
  checking: boolean;
  quantity: string;
  colormap: string;
  animate: boolean;
  canAnimate: boolean;
  quantities: {value: string; label: string}[];
  colormaps: {value: string; label: string}[];
  onBackToBrowser: () => void;
  onOpenPuzzle: (id: string) => void;
  onCheck: () => void;
  onReset: () => void;
  onLoadReference: () => void;
  onAddPart: (paletteIndex: number) => void;
  onSelect: (item: Item | null) => void;
  onEdit: (change: (draft: Scene) => void) => void;
  onDuplicate: (item: Item) => void;
  onDelete: (item: Item) => void;
  onQuantity: (v: string) => void;
  onColormap: (v: string) => void;
  onAnimate: (v: boolean) => void;
}

export function PuzzlePanel({
  puzzle,
  puzzles,
  progress,
  scene,
  presets,
  selected,
  ruleCheck,
  evaluation,
  checkCurrent,
  checking,
  quantity,
  colormap,
  animate,
  canAnimate,
  quantities,
  colormaps,
  onBackToBrowser,
  onOpenPuzzle,
  onCheck,
  onReset,
  onLoadReference,
  onAddPart,
  onSelect,
  onEdit,
  onDuplicate,
  onDelete,
  onQuantity,
  onColormap,
  onAnimate,
}: Props) {
  const [hintsShown, setHintsShown] = useState(0);

  useEffect(() => {
    setHintsShown(0);
  }, [puzzle.id]);

  const idx = puzzles.findIndex((p) => p.id === puzzle.id);
  const prev = idx > 0 ? puzzles[idx - 1] : null;
  const next = idx >= 0 && idx < puzzles.length - 1 ? puzzles[idx + 1] : null;

  const locked = lockedIds(puzzle);
  const design = extractDesign(puzzle, scene);
  const usage = paletteUsage(puzzle, design, presets);
  const enabledCount = enabledDesignCount(design);
  const scale = puzzleScoreScale(puzzle);
  const validEval = evaluation?.valid && checkCurrent ? evaluation : null;
  const score = validEval?.score ?? null;
  const stars = validEval?.stars ?? 0;
  const hints = puzzle.hints ?? [];

  // Progress meter upper bound: slightly past 3-star threshold so the 3rd star sits nicely inside the track.
  const maxBar = Math.max(puzzle.stars[2] * 1.15, score ?? 0, 1);
  const pct = (v: number) => `${Math.max(0, Math.min(100, (v / maxBar) * 100))}%`;

  const selectedIsPlayer = selected?.kind === 'element' && !locked.has(selected.id);
  const canDupSelected = (() => {
    if (!selectedIsPlayer || !selected) return false;
    const el = scene.elements.find((e) => e.id === selected.id);
    if (!el) return false;
    const kind = String((el.shape as Json | undefined)?.kind ?? '');
    const pi = puzzle.rules.palette.findIndex((entry) => entry.kind === kind);
    return pi >= 0 && canAddPalettePart(puzzle, design, pi, presets);
  })();

  const ruleErrors = (
    evaluation && !evaluation.valid && checkCurrent ? evaluation.issues : ruleCheck?.issues ?? []
  ).filter((i) => i.severity === 'error');

  return (
    <VStack gap={0}>
      {/* Puzzle navigation */}
      <Section variant="transparent" padding={4}>
        <VStack gap={3}>
          <HStack gap={1} vAlign="center" hAlign="between">
            <Button
              label="All puzzles"
              size="sm"
              variant="ghost"
              icon={<Icon icon={Squares2X2Icon} size="sm" />}
              onClick={onBackToBrowser}
            />
            <HStack gap={1}>
              <Button
                label="Previous puzzle"
                size="sm"
                variant="ghost"
                isIconOnly
                isDisabled={!prev}
                tooltip={prev ? `Previous: ${prev.title}` : undefined}
                icon={<Icon icon={ChevronLeftIcon} size="sm" />}
                onClick={() => prev && onOpenPuzzle(prev.id)}
              />
              <Button
                label="Next puzzle"
                size="sm"
                variant="ghost"
                isIconOnly
                isDisabled={!next}
                tooltip={next ? `Next: ${next.title}` : undefined}
                icon={<Icon icon={ChevronRightIcon} size="sm" />}
                onClick={() => next && onOpenPuzzle(next.id)}
              />
            </HStack>
          </HStack>
          <Selector
            label="Puzzle"
            size="sm"
            value={puzzle.id}
            options={puzzles.map((p) => ({value: p.id, label: `${p.chapter_title}: ${p.title}`}))}
            onChange={(id) => {
              if (id && id !== puzzle.id) onOpenPuzzle(id);
            }}
          />
          <Text type="supporting">{puzzle.summary}</Text>
        </VStack>
      </Section>

      <Divider />

      {/* Goal card */}
      <Section variant="transparent" padding={4}>
        <div className="goal-card">
          <VStack gap={3}>
            <VStack gap={1}>
              <Text type="supporting" weight="semibold" color="secondary">
                Goal
              </Text>
              <Text weight="semibold">{puzzleTaskLine(puzzle)}</Text>
              <Text type="supporting" color="secondary">
                {puzzlePassLine(puzzle)}
              </Text>
            </VStack>

            {/* Score bar with 3 star thresholds */}
            <div className="score-track-wrap">
              <div className="score-track">
                {score !== null && (
                  <div
                    className={`score-fill${validEval?.passed ? ' score-fill-pass' : ' score-fill-fail'}`}
                    style={{width: pct(Math.max(0, score))}}
                  />
                )}
                {puzzle.stars.map((th, i) => (
                  <span
                    key={i}
                    className={`score-tick${score !== null && score >= th && validEval?.passed ? ' score-tick-hit' : ''}`}
                    style={{left: pct(th)}}
                    title={`Star ${i + 1}: ${formatThreshold(scale, th)}`}
                  />
                ))}
              </div>
              <HStack gap={2} vAlign="center" hAlign="between">
                <Text type="supporting" color="secondary" hasTabularNumbers>
                  {puzzleStarsLine(puzzle)}
                </Text>
                <span className="puzzle-stars">
                  {[1, 2, 3].map((n) => (
                    <Icon
                      key={n}
                      icon={n <= stars ? StarSolid : StarOutline}
                      size="xsm"
                      color={n <= stars ? 'warning' : 'secondary'}
                    />
                  ))}
                </span>
              </HStack>
            </div>

            {/* Verdict / status */}
            {checking ? (
              <Text type="supporting" color="secondary">
                Measuring every case…
              </Text>
            ) : validEval ? (
              <VStack gap={1}>
                <HStack gap={1} vAlign="center">
                  <Icon
                    icon={validEval.passed ? CheckCircleIcon : XCircleIcon}
                    size="xsm"
                    color={validEval.passed ? 'success' : 'error'}
                  />
                  <Text type="supporting" weight="semibold" hasTabularNumbers>
                    {validEval.passed
                      ? `Passed · ${validEval.stars} of 3 stars (${formatScore(scale, score)})`
                      : `Not passed yet: ${formatScore(scale, score)} (needs ${formatThreshold(scale, puzzle.goal.pass)})`}
                  </Text>
                </HStack>
                {validEval.passed && next && (
                  <Button
                    label={`Next: ${next.title}`}
                    size="sm"
                    variant="secondary"
                    onClick={() => onOpenPuzzle(next.id)}
                  />
                )}
              </VStack>
            ) : ruleErrors.length > 0 ? (
              <VStack gap={1}>
                {ruleErrors.map((err, i) => (
                  <HStack key={i} gap={1} vAlign="start">
                    <Icon icon={XCircleIcon} size="xsm" color="error" />
                    <Text type="supporting">{err.message}</Text>
                  </HStack>
                ))}
              </VStack>
            ) : (
              <Text type="supporting" color="secondary" hasTabularNumbers>
                {progress?.bestScore !== undefined
                  ? `Best so far: ${formatScore(scale, progress.bestScore)} (${progress.stars} of 3 stars)`
                  : 'Place your parts, then click Check to score.'}
              </Text>
            )}

            <HStack gap={2}>
              <Button
                label={checking ? 'Checking…' : 'Check'}
                variant="primary"
                size="sm"
                isLoading={checking}
                onClick={onCheck}
              />
              <Button
                label="Reset"
                variant="ghost"
                size="sm"
                icon={<Icon icon={ArrowPathIcon} size="sm" />}
                onClick={onReset}
              />
            </HStack>
          </VStack>
        </div>
      </Section>

      <Divider />

      {/* Parts palette */}
      <PanelSection
        id="puzzle.parts"
        title="Parts"
        gap={3}
        aside={
          puzzle.rules.max_elements !== undefined && (
            <Badge
              variant={enabledCount >= puzzle.rules.max_elements ? 'warning' : 'neutral'}
              label={`${enabledCount} / ${puzzle.rules.max_elements}`}
            />
          )
        }
      >
          <VStack gap={2}>
            {puzzle.rules.palette.map((entry, i) => {
              const allowed = canAddPalettePart(puzzle, design, i, presets);
              const count = usage[i] ?? 0;
              const cap = entry.max !== undefined ? `${count}/${entry.max}` : `${count}`;
              return (
                <div key={`${entry.kind}-${i}`} className="palette-row">
                  <div className="palette-info">
                    <Text type="supporting" weight="semibold">
                      {SHAPE_TITLES[entry.kind] ?? entry.kind}
                    </Text>
                    <Text type="supporting" color="secondary">
                      {paletteEntryLabel(puzzle, entry, presets)}
                    </Text>
                  </div>
                  <Button
                    label={`Add (${cap})`}
                    size="sm"
                    variant="secondary"
                    isDisabled={!allowed}
                    icon={<Icon icon={PlusIcon} size="sm" />}
                    onClick={() => onAddPart(i)}
                  />
                </div>
              );
            })}
          </VStack>

          {/* Placed parts + locked parts list */}
          {scene.elements.length > 0 && (
            <VStack gap={1}>
              {scene.elements.map((el, index) => {
                const isLock = locked.has(String(el.id));
                const item = makeItem('element', scene.elements, index);
                const isSel = sameItem(selected, item);
                return (
                  <div
                    key={String(el.id ?? index)}
                    className={`obj-row${isSel ? ' obj-row-selected' : ''}${isLock ? ' obj-row-locked' : ''}`}
                    onClick={() => !isLock && onSelect(item)}
                  >
                    <span className="obj-row-name">
                      {isLock && <Icon icon={LockClosedIcon} size="xsm" color="secondary" />}
                      <Text type="supporting" weight={isSel ? 'semibold' : undefined} color={isLock ? 'secondary' : 'primary'}>
                        {titleOf(scene, item)}
                      </Text>
                    </span>
                    {!isLock && (
                      <Button
                        label="Delete part"
                        size="sm"
                        variant="ghost"
                        isIconOnly
                        icon={<Icon icon={TrashIcon} size="sm" />}
                        onClick={(e) => {
                          e.stopPropagation();
                          onDelete(item);
                        }}
                      />
                    )}
                  </div>
                );
              })}
            </VStack>
          )}
      </PanelSection>

      {/* Selected player part inspector */}
      {selectedIsPlayer && selected && (
        <>
          <Divider />
          <Inspector
            scene={scene}
            item={selected}
            presets={presets}
            puzzle={puzzle}
            canDuplicate={canDupSelected}
            canDelete={true}
            onEdit={onEdit}
            onDuplicate={() => onDuplicate(selected)}
            onDelete={() => onDelete(selected)}
            onClose={() => onSelect(null)}
          />
        </>
      )}

      <Divider />

      {/* Hints & reference solution */}
      <PanelSection id="puzzle.hints" title="Hints" gap={3}>
          <HStack>
            <Button
              label="Load solution"
              size="sm"
              variant="ghost"
              icon={<Icon icon={SparklesIcon} size="sm" />}
              tooltip="Load the reference solution and run Check"
              onClick={onLoadReference}
            />
          </HStack>
          {hints.slice(0, hintsShown).map((hint, i) => (
            <div key={i} className="hint-box">
              <Text type="supporting">{hint}</Text>
            </div>
          ))}
          {hintsShown < hints.length && (
            <Button
              label={`Show hint ${hintsShown + 1} of ${hints.length}`}
              size="sm"
              variant="secondary"
              icon={<Icon icon={LightBulbIcon} size="sm" />}
              onClick={() => setHintsShown((h) => h + 1)}
            />
          )}
      </PanelSection>

      <Divider />

      {/* Display */}
      <Section variant="transparent" padding={4}>
        <Collapsible trigger={<Heading level={3}>Display</Heading>} defaultIsOpen={false}>
          <VStack gap={3} style={{paddingTop: 12}}>
            <div className="fit-segments">
              <SegmentedControl label="Show" value={quantity} onChange={onQuantity}>
                {quantities.map((q) => (
                  <SegmentedControlItem key={q.value} value={q.value} label={q.label} />
                ))}
              </SegmentedControl>
            </div>
            <Selector label="Colors" value={colormap} onChange={onColormap} options={colormaps} />
            <Switch
              label="Animate the wave"
              description={canAnimate ? undefined : 'For the field and phase views.'}
              value={animate}
              isDisabled={!canAnimate}
              onChange={onAnimate}
            />
          </VStack>
        </Collapsible>
      </Section>
    </VStack>
  );
}
