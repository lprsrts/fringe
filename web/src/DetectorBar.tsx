// Live detector readings strip shown right under the canvas in Simulator mode.
import {Text} from '@astryxdesign/core/Text';
import type {DetectorReading} from './solver';
import {
  formatFixed,
  formatSig,
  makeItem,
  meaningfulRatio,
  readingIncident,
  readingTotal,
  sameItem,
  titleOf,
  type Item,
  type Json,
  type Scene,
} from './scene';

interface Props {
  scene: Scene;
  readings: DetectorReading[];
  incidentPeak: number;
  stale: boolean;
  selected: Item | null;
  onSelect: (item: Item) => void;
}

export function DetectorBar({scene, readings, incidentPeak, stale, selected, onSelect}: Props) {
  if (scene.detectors.length === 0) return null;
  const byId = new Map(readings.map((r) => [r.id, r]));

  return (
    <div className={`results-strip${stale ? ' results-stale' : ''}`} role="region" aria-label="Detector readings">
      <table className="data-table">
        <thead>
          <tr>
            <th>Detector</th>
            <th>Kind</th>
            <th className="num">Total</th>
            <th className="num">Incident</th>
            <th className="num">Ratio</th>
          </tr>
        </thead>
        <tbody>
          {scene.detectors.map((det, index) => {
            const item = makeItem('detector', scene.detectors, index);
            const isSel = sameItem(selected, item);
            const enabled = det.enabled !== false;
            const reading = byId.get(String(det.id));
            const kind = String((det.shape as Json | undefined)?.kind ?? 'line');
            const total = reading ? readingTotal(reading) : null;
            const inc = reading ? readingIncident(reading) : null;
            const ratio = reading ? meaningfulRatio(reading, readings, incidentPeak) : null;
            return (
              <tr
                key={String(det.id ?? index)}
                className={`clickable-row${isSel ? ' selected-row' : ''}${enabled ? '' : ' disabled-row'}`}
                onClick={() => onSelect(item)}
              >
                <td>
                  <Text type="supporting" weight={isSel ? 'semibold' : undefined}>
                    {titleOf(scene, item)}
                  </Text>
                </td>
                <td>
                  <Text type="supporting" color="secondary">
                    {kind === 'box' ? 'Box (|E|²)' : 'Line (flux)'}
                  </Text>
                </td>
                <td className="num mono">{!enabled ? 'Off' : total !== null ? formatSig(total) : '—'}</td>
                <td className="num mono">{!enabled ? '' : inc !== null ? formatSig(inc) : '—'}</td>
                <td className="num mono">{!enabled ? '' : ratio !== null ? `${formatFixed(ratio, 2)}×` : '—'}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
