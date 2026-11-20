// Results strip under the canvas in Puzzle mode:
// - Truth-table puzzles (Half adder, XOR, AND, ...): input toggles + clickable
//   case rows with live switching and post-Check case-by-case reveal.
// - Single-case puzzles (Dark spot, Split a beam, ...): live detector preview
//   reading under the canvas + checked score and goal verdict.
import {Badge} from '@astryxdesign/core/Badge';
import {Button} from '@astryxdesign/core/Button';
import {Icon} from '@astryxdesign/core/Icon';
import {HStack} from '@astryxdesign/core/Layout';
import {Text} from '@astryxdesign/core/Text';
import {ToggleButton} from '@astryxdesign/core/ToggleButton';
import {CheckCircleIcon, XCircleIcon} from '@heroicons/react/20/solid';

import type {DetectorReading, Puzzle, PuzzleEvaluation} from './solver';
import {
  allCases,
  bitsEqual,
  buildTruthRows,
  computePuzzleLiveValue,
  detectorDisplayName,
  formatPuzzleValue,
  formatThreshold,
  goalDetectorIds,
  inputLetters,
  puzzleScoreScale,
} from './puzzle';

interface Props {
  puzzle: Puzzle;
  bits: boolean[];
  readings: DetectorReading[];
  readingsStale: boolean;
  allSourcesOff: boolean;
  evaluation: PuzzleEvaluation | null;
  checkCurrent: boolean;
  checking: boolean;
  /** While revealing cases after Check: index of the case currently shown, else null. */
  revealCase: number | null;
  onToggleInput: (index: number, on: boolean) => void;
  onSelectCase: (bits: boolean[]) => void;
  onCheck: () => void;
  onSkipReveal: () => void;
}

export function PuzzleResultsBar({
  puzzle,
  bits,
  readings,
  readingsStale,
  allSourcesOff,
  evaluation,
  checkCurrent,
  checking,
  revealCase,
  onToggleInput,
  onSelectCase,
  onCheck,
  onSkipReveal,
}: Props) {
  const isTruth = puzzle.goal.type === 'truth_table';
  const letters = inputLetters(puzzle.inputs);
  const cases = allCases(puzzle.inputs);
  const validEval = evaluation?.valid ? evaluation : null;
  const stale = validEval !== null && !checkCurrent;
  const revealing = revealCase !== null;
  const scale = puzzleScoreScale(puzzle);

  if (isTruth) {
    const rows = buildTruthRows(puzzle, validEval);
    const outputs = puzzle.goal.outputs ?? [];
    const activeIdx = revealing ? revealCase : cases.findIndex((c) => bitsEqual(c, bits));

    return (
      <div className="results-strip puzzle-results" role="region" aria-label="Truth table">
        <HStack gap={2} vAlign="center" hAlign="between" style={{flexWrap: 'wrap', marginBottom: 8}}>
          <HStack gap={2} vAlign="center" style={{flexWrap: 'wrap'}}>
            <Text type="supporting" weight="semibold">
              Inputs
            </Text>
            {letters.map((letter, i) => {
              const on = bits[i] ?? false;
              return (
                <ToggleButton
                  key={letter}
                  label={`${letter} = ${on ? '1' : '0'}`}
                  size="sm"
                  isPressed={on}
                  isDisabled={revealing}
                  onPressedChange={(next) => onToggleInput(i, next)}
                />
              );
            })}
            {activeIdx >= 0 && (
              <Text type="supporting" color="secondary" hasTabularNumbers>
                {revealing ? `Checking case ${activeIdx + 1} of ${cases.length}` : `Case ${activeIdx + 1} of ${cases.length}`}
              </Text>
            )}
            {stale && <Badge variant="warning" label="Out of date" />}
          </HStack>
          <HStack gap={2} vAlign="center">
            {revealing ? (
              <Button label="Skip reveal" size="sm" variant="ghost" onClick={onSkipReveal} />
            ) : (
              <Button
                label={checking ? 'Checking…' : 'Check'}
                size="sm"
                variant={checkCurrent ? 'secondary' : 'primary'}
                isLoading={checking}
                onClick={onCheck}
              />
            )}
          </HStack>
        </HStack>

        <div className="table-scroll">
          <table className={`data-table truth-table${stale ? ' results-stale' : ''}`}>
            <thead>
              <tr>
                {letters.map((l) => (
                  <th key={l} className="center">
                    {l}
                  </th>
                ))}
                {outputs.map((o) => (
                  <th key={`${o.detector}-head`} colSpan={2} className="center">
                    {detectorDisplayName(puzzle, o.detector)}
                  </th>
                ))}
                <th className="center" aria-label="Verdict" />
              </tr>
              <tr className="subhead">
                {letters.map((l) => (
                  <th key={`${l}-sub`} />
                ))}
                {outputs.map((o) => (
                  <FragmentPair key={`${o.detector}-sub`} />
                ))}
                <th />
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => {
                const shown = revealing ? revealCase === row.caseIndex : bitsEqual(row.bits, bits);
                const revealed = !revealing || row.caseIndex <= revealCase;
                return (
                  <tr
                    key={row.caseIndex}
                    className={`clickable-row${shown ? ' selected-row' : ''}`}
                    onClick={() => {
                      if (revealing) onSkipReveal();
                      onSelectCase(row.bits);
                    }}
                  >
                    {row.bits.map((b, i) => (
                      <td key={i} className="center mono">
                        {b ? '1' : '0'}
                      </td>
                    ))}
                    {row.cells.map((cell) => (
                      <FragmentCells
                        key={cell.detector}
                        target={cell.target}
                        value={revealed && validEval ? formatPuzzleValue(puzzle, cell.value) : '—'}
                        decisive={revealed && !stale && cell.decisive}
                      />
                    ))}
                    <td className="center verdict-cell">
                      {revealed && !stale && row.passes !== null && (
                        <Icon
                          icon={row.passes ? CheckCircleIcon : XCircleIcon}
                          size="xsm"
                          color={row.passes ? 'success' : 'error'}
                        />
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        <div className="results-footnote">
          <Text type="supporting" color="secondary" hasTabularNumbers>
            {checking
              ? 'Solving each input source…'
              : evaluation && !evaluation.valid && !stale
                ? 'Not scored: the design breaks a rule.'
                : validEval?.metric?.text && !revealing
                  ? validEval.metric.text
                  : 'Click any row to inspect that case. Check scores every case at once.'}
          </Text>
        </div>
      </div>
    );
  }

  // Single-case puzzles (Dark spot, Split a beam, Focus, Shade the detector, …).
  const detIds = goalDetectorIds(puzzle);
  const readingMap = new Map(readings.map((r) => [r.id, r]));
  const evalOutputs = validEval?.cases[0]?.outputs ?? [];

  const goalText = (id: string) => {
    const g = puzzle.goal;
    if (g.type === 'maximize') return `≥ ${formatThreshold(scale, g.pass)}`;
    if (g.type === 'minimize') {
      const pct = 10 ** (-g.pass / 10) * 100;
      const fmt = pct < 1 ? pct.toFixed(2) : pct.toFixed(0);
      return detIds.length > 1 ? `≤ ${fmt}% total` : `≤ ${fmt}%`;
    }
    if (g.type === 'target' && g.ratio !== undefined && g.tolerance !== undefined) {
      const share = id === detIds[0] ? g.ratio : 1 - g.ratio;
      return `${Math.round(share * 100)}% ± ${Math.round(g.tolerance * 100)}`;
    }
    return '';
  };

  return (
    <div className="results-strip puzzle-results" role="region" aria-label="Puzzle detector readings">
      <HStack gap={2} vAlign="center" hAlign="between" style={{flexWrap: 'wrap', marginBottom: 6}}>
        <HStack gap={2} vAlign="center">
          <Text type="supporting" weight="semibold">
            {detIds.length > 1 ? 'Goal detectors' : 'Live reading'}
          </Text>
          {stale && <Badge variant="warning" label="Out of date" />}
        </HStack>
        <Button
          label={checking ? 'Checking…' : 'Check'}
          size="sm"
          variant={checkCurrent ? 'secondary' : 'primary'}
          isLoading={checking}
          onClick={onCheck}
        />
      </HStack>
      <table className={`data-table${readingsStale && !checkCurrent ? ' results-stale' : ''}`}>
        <thead>
          <tr>
            <th>Detector</th>
            <th className="num">Live</th>
            <th className="num">Checked</th>
            <th className="num">Goal</th>
            <th className="center" aria-label="Verdict" />
          </tr>
        </thead>
        <tbody>
          {detIds.map((id) => {
            const r = readingMap.get(id);
            const liveVal = r ? computePuzzleLiveValue(puzzle, r, allSourcesOff) : null;
            const checkedOut = evalOutputs.find((o) => o.detector === id);
            return (
              <tr key={id}>
                <td>
                  <Text type="supporting" weight="semibold">
                    {detectorDisplayName(puzzle, id)}
                  </Text>
                </td>
                <td className="num mono">
                  {liveVal !== null ? formatPuzzleValue(puzzle, liveVal) : '—'}
                </td>
                <td className="num mono">
                  {validEval && !stale && checkedOut?.value !== undefined ? formatPuzzleValue(puzzle, checkedOut.value) : '—'}
                </td>
                <td className="num mono">{goalText(id)}</td>
                <td className="center verdict-cell">
                  {validEval && !stale && (
                    <Icon
                      icon={validEval.passed ? CheckCircleIcon : XCircleIcon}
                      size="xsm"
                      color={validEval.passed ? 'success' : 'error'}
                    />
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {validEval?.metric?.text && !stale && (
        <div className="results-footnote">
          <Text type="supporting" color="secondary">
            {validEval.metric.text}
          </Text>
        </div>
      )}
    </div>
  );
}

function FragmentPair() {
  return (
    <>
      <th className="center">Want</th>
      <th className="num">Got</th>
    </>
  );
}

function FragmentCells({target, value, decisive}: {target: boolean; value: string; decisive: boolean}) {
  return (
    <>
      <td className="center mono">{target ? '1' : '0'}</td>
      <td className={`num mono${decisive ? ' decisive-cell' : ''}`}>{value}</td>
    </>
  );
}
