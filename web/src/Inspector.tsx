// Inspector for the selected element, source or detector. Supports editing
// geometry, materials (dielectric, PEC, dispersive presets, or puzzle-allowed
// materials), source type, detector kind/direction, duplicating and deleting.
import {Button} from '@astryxdesign/core/Button';
import {Icon} from '@astryxdesign/core/Icon';
import {HStack, VStack} from '@astryxdesign/core/Layout';
import {NumberInput} from '@astryxdesign/core/NumberInput';
import {Section} from '@astryxdesign/core/Section';
import {SegmentedControl, SegmentedControlItem} from '@astryxdesign/core/SegmentedControl';
import {Selector} from '@astryxdesign/core/Selector';
import {Switch} from '@astryxdesign/core/Switch';
import {Heading, Text} from '@astryxdesign/core/Text';
import {TextInput} from '@astryxdesign/core/TextInput';
import {ArrowsRightLeftIcon, DocumentDuplicateIcon, TrashIcon, XMarkIcon} from '@heroicons/react/24/outline';

import type {DetectorReading, MaterialPreset, Puzzle} from './solver';
import {
  convertDetectorKind,
  flipLineDetector,
  formatReadingBadge,
  labelOf,
  materialKey,
  numericKeys,
  objectOf,
  PEC_ONLY_SHAPES,
  sameMaterial,
  titleOf,
  type Item,
  type Json,
  type Scene,
} from './scene';
import {allowedMaterialsForKind, paletteMaterialTitle, resolvePaletteMaterial} from './puzzle';

interface Props {
  scene: Scene;
  item: Item;
  presets: MaterialPreset[];
  readings?: DetectorReading[];
  incidentPeak?: number;
  solverMethod?: string;
  /** Set when editing a player part inside a puzzle: restricts materials and locks name/type. */
  puzzle?: Puzzle | null;
  canDuplicate?: boolean;
  canDelete?: boolean;
  onEdit: (change: (draft: Scene) => void) => void;
  onSwitchSolver?: (method: string) => void;
  onDuplicate?: () => void;
  onDelete?: () => void;
  onClose: () => void;
}

const stepFor = (key: string) =>
  key.endsWith('_deg') ? 1 : key === 'count' ? 1 : key === 'n' || key === 'k' || key === 'fill_factor' ? 0.01 : 0.1;

export function Inspector({
  scene,
  item,
  presets,
  readings = [],
  incidentPeak = 1,
  solverMethod,
  puzzle = null,
  canDuplicate = true,
  canDelete = true,
  onEdit,
  onSwitchSolver,
  onDuplicate,
  onDelete,
  onClose,
}: Props) {
  const o = objectOf(scene, item);
  if (!o) return null;

  const shape = (o.shape ?? null) as Json | null;
  const material = (o.material ?? null) as Json | null;
  const shapeKind = String(shape?.kind ?? '');
  const own = (draft: Scene) => objectOf(draft, item)!;

  const numField = (path: (draft: Scene) => Json, key: string, value: number) => {
    const {label, unit} = labelOf(key);
    return (
      <NumberInput
        key={key}
        label={unit ? `${label} (${unit})` : label}
        value={value}
        step={stepFor(key)}
        min={
          key === 'count' ? 1
          : key === 'n' ? 0.1
          : key === 'k' || key === 'substrate_um' ? 0
          : key === 'fill_factor' ? 0.05
          : key === 'waist_um' || key === 'amplitude' || key === 'thickness_um' || key === 'height_um'
              || key === 'width_um' || key === 'length_um' || key === 'radius_um' && shapeKind === 'cylinder'
              || key === 'aperture_um' || key === 'center_thickness_um' || key === 'period_um'
              || key === 'depth_um' || key === 'base_um' || key === 'slit_width_um' || key === 'pitch_um'
              || key === 'screen_height_um' ? 0.02
          : undefined
        }
        max={key === 'fill_factor' ? 0.95 : undefined}
        onChange={(v) => onEdit((draft) => void (path(draft)[key] = key === 'count' ? Math.max(1, Math.round(v)) : v))}
        size="sm"
      />
    );
  };

  // Element numeric fields: always expose rotation_deg even when omitted in JSON.
  const ownKeys = item.kind === 'element'
    ? ['x_um', 'y_um', 'rotation_deg', ...numericKeys(o, ['x_um', 'y_um', 'rotation_deg'])]
    : item.kind === 'source'
      ? [...numericKeys(o, ['amplitude', 'phase_deg']), 'amplitude', 'phase_deg']
      : numericKeys(o);

  // ---- Material selector (elements)
  const renderMaterial = () => {
    if (item.kind !== 'element' || !material) return null;
    if (PEC_ONLY_SHAPES.has(shapeKind)) {
      return <Text type="supporting">Material: perfect conductor (PEC)</Text>;
    }
    if (puzzle) {
      const allowed = allowedMaterialsForKind(puzzle, shapeKind);
      if (allowed && allowed.length === 1) {
        return <Text type="supporting">Material: {paletteMaterialTitle(puzzle, allowed[0], presets)}</Text>;
      }
      if (allowed && allowed.length > 1) {
        const currentName =
          allowed.find((name) => sameMaterial(material, resolvePaletteMaterial(puzzle, name, presets) ?? undefined)) ?? allowed[0];
        return (
          <Selector
            label="Material"
            size="sm"
            value={currentName}
            options={allowed.map((name) => ({value: name, label: paletteMaterialTitle(puzzle, name, presets)}))}
            onChange={(name) => {
              const mat = resolvePaletteMaterial(puzzle, name, presets);
              if (mat) onEdit((draft) => void (own(draft).material = mat));
            }}
          />
        );
      }
    }

    const currentKey = materialKey(material, presets);
    const options = [
      {value: 'dielectric', label: 'Dielectric (n, k)'},
      {value: 'pec', label: 'Perfect conductor (PEC)'},
      ...presets.map((p) => ({value: `preset:${p.id}`, label: p.name})),
      ...(currentKey === 'dispersive-custom' ? [{value: 'dispersive-custom', label: 'Custom dispersive'}] : []),
    ];

    return (
      <VStack gap={3}>
        <Selector
          label="Material"
          size="sm"
          value={currentKey}
          options={options}
          onChange={(val) => {
            onEdit((draft) => {
              const target = own(draft);
              if (val === 'pec') {
                target.material = {type: 'pec'};
              } else if (val === 'dielectric') {
                const prev = target.material as Json | undefined;
                target.material = {
                  type: 'dielectric',
                  n: prev?.type === 'dielectric' ? Number(prev.n ?? 1.5) : 1.5,
                  k: prev?.type === 'dielectric' ? Number(prev.k ?? 0) : 0,
                };
              } else if (val.startsWith('preset:')) {
                const id = val.slice(7);
                const preset = presets.find((p) => p.id === id);
                if (preset) target.material = structuredClone(preset.material);
              }
            });
          }}
        />
        {material.type === 'dielectric' && (
          <div className="field-grid">
            {numField((d) => own(d).material as Json, 'n', Number(material.n ?? 1.5))}
            {numField((d) => own(d).material as Json, 'k', Number(material.k ?? 0))}
          </div>
        )}
        {material.type === 'dispersive' &&
          presets.find((p) => p.id === material.preset)?.kind === 'metal' &&
          solverMethod === 'fdtd' &&
          onSwitchSolver && (
            <HStack gap={2} vAlign="center" hAlign="between">
              <Text type="supporting" color="secondary">
                Dispersive metals need a fine grid in FDTD; MoM is faster for small metal parts.
              </Text>
              <Button label="Use MoM" size="sm" variant="secondary" onClick={() => onSwitchSolver('mom')} />
            </HStack>
          )}
      </VStack>
    );
  };

  // ---- Shape controls (including nullable flat radii for lenses & mirrors)
  const renderShape = () => {
    if (!shape) return null;
    if (item.kind === 'detector') {
      const detKind = String(shape.kind ?? 'line') as 'line' | 'box';
      const detReading = readings.find((r) => r.id === String(o.id));
      const lambdaB = scene.wavelength_um / Math.max(0.1, scene.background.n);
      return (
        <VStack gap={3}>
          <SegmentedControl
            label="Detector shape"
            value={detKind}
            onChange={(next) =>
              onEdit((draft) => convertDetectorKind(own(draft), next as 'line' | 'box', lambdaB))
            }
          >
            <SegmentedControlItem value="line" label="Line" />
            <SegmentedControlItem value="box" label="Box" />
          </SegmentedControl>
          <div className="field-grid">
            {numericKeys(shape).map((k) => numField((d) => own(d).shape as Json, k, Number(shape[k])))}
          </div>
          {detKind === 'line' && (
            <Button
              label="Flip direction"
              size="sm"
              variant="secondary"
              icon={<Icon icon={ArrowsRightLeftIcon} size="sm" />}
              onClick={() => onEdit((draft) => flipLineDetector(own(draft)))}
            />
          )}
          {detReading && (
            <Text type="supporting" hasTabularNumbers>
              Reading: {formatReadingBadge(detReading, readings, incidentPeak)}
            </Text>
          )}
        </VStack>
      );
    }

    const nullableRadii = shapeKind === 'lens' ? (['r1_um', 'r2_um'] as const) : shapeKind === 'mirror' ? (['radius_um'] as const) : [];
    const standardKeys = numericKeys(shape, [...nullableRadii]);

    return (
      <VStack gap={3}>
        <Text type="label" weight="semibold">
          Shape
        </Text>
        <div className="field-grid">
          {standardKeys.map((k) => numField((d) => own(d).shape as Json, k, Number(shape[k])))}
        </div>
        {nullableRadii.map((rk) => {
          const val = shape[rk];
          const isFlat = val === null || val === undefined;
          const {label, unit} = labelOf(rk);
          const defaultRadius = rk === 'r2_um' ? -12 : 12;
          return (
            <HStack key={rk} gap={2} vAlign="end">
              <div style={{flex: 1}}>
                {isFlat ? (
                  <Text type="supporting">{label}: flat</Text>
                ) : (
                  numField((d) => own(d).shape as Json, rk, Number(val))
                )}
              </div>
              <Button
                label={isFlat ? 'Curve' : 'Flat'}
                size="sm"
                variant="ghost"
                tooltip={isFlat ? `Set ${label} (${unit})` : `Make ${label} flat`}
                onClick={() =>
                  onEdit((draft) => {
                    const s = own(draft).shape as Json;
                    s[rk] = isFlat ? defaultRadius : null;
                  })
                }
              />
            </HStack>
          );
        })}
      </VStack>
    );
  };

  // ---- Source type switcher (simulator mode)
  const renderSourceType = () => {
    if (item.kind !== 'source' || puzzle) return null;
    const type = String(o.type ?? 'gaussian_beam');
    const d = scene.domain;
    const cx = (d.x_min_um + d.x_max_um) / 2;
    const cy = (d.y_min_um + d.y_max_um) / 2;
    return (
      <SegmentedControl
        label="Source type"
        value={type}
        onChange={(next) => {
          if (next === type) return;
          onEdit((draft) => {
            const cur = own(draft);
            const common = {
              id: cur.id,
              name: cur.name,
              enabled: cur.enabled !== false,
              amplitude: Number(cur.amplitude ?? 1),
              phase_deg: Number(cur.phase_deg ?? 0),
            };
            const x = Number(cur.waist_x_um ?? cur.x_um ?? cx);
            const y = Number(cur.waist_y_um ?? cur.y_um ?? cy);
            const angle = Number(cur.angle_deg ?? 0);
            const replacement: Json =
              next === 'plane_wave'
                ? {...common, type: 'plane_wave', angle_deg: angle}
                : next === 'line_source'
                  ? {...common, type: 'line_source', x_um: x, y_um: y}
                  : {...common, type: 'gaussian_beam', waist_um: Number(cur.waist_um ?? 2), waist_x_um: x, waist_y_um: y, angle_deg: angle};
            const list = draft.sources;
            const idx = list.findIndex((s) => s.id === cur.id);
            if (idx >= 0) list[idx] = replacement;
          });
        }}
      >
        <SegmentedControlItem value="gaussian_beam" label="Beam" />
        <SegmentedControlItem value="plane_wave" label="Plane" />
        <SegmentedControlItem value="line_source" label="Emitter" />
      </SegmentedControl>
    );
  };

  return (
    <Section variant="transparent" padding={4}>
      <VStack gap={3}>
        <HStack gap={1} vAlign="center" hAlign="between">
          <Heading level={3}>{titleOf(scene, item)}</Heading>
          <HStack gap={1}>
            {onDuplicate && (
              <Button
                label="Duplicate"
                variant="ghost"
                size="sm"
                isIconOnly
                isDisabled={!canDuplicate}
                tooltip="Duplicate"
                icon={<Icon icon={DocumentDuplicateIcon} size="sm" />}
                onClick={onDuplicate}
              />
            )}
            {onDelete && (
              <Button
                label="Delete"
                variant="ghost"
                size="sm"
                isIconOnly
                isDisabled={!canDelete}
                tooltip="Delete"
                icon={<Icon icon={TrashIcon} size="sm" />}
                onClick={onDelete}
              />
            )}
            <Button label="Deselect" variant="ghost" size="sm" isIconOnly icon={<Icon icon={XMarkIcon} size="sm" />} onClick={onClose} />
          </HStack>
        </HStack>

        {!puzzle && (
          <TextInput
            label="Name"
            size="sm"
            value={String(o.name ?? '')}
            placeholder={titleOf(scene, item)}
            onChange={(v) => onEdit((draft) => void (own(draft).name = v))}
          />
        )}

        <Switch
          label="Enabled"
          size="sm"
          value={o.enabled !== false}
          onChange={(on) => onEdit((draft) => void (own(draft).enabled = on))}
        />

        {renderSourceType()}

        {ownKeys.length > 0 && (
          <div className="field-grid">
            {ownKeys.map((k) =>
              numField(own, k, Number(o[k] ?? (k === 'amplitude' ? 1 : 0))),
            )}
          </div>
        )}

        {renderMaterial()}
        {renderShape()}
      </VStack>
    </Section>
  );
}
