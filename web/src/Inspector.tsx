// Fields for the selected element or source, generated from its numbers in the
// scene, so every shape the core knows gets a form without a table of shapes.
import {Button} from '@astryxdesign/core/Button';
import {Icon} from '@astryxdesign/core/Icon';
import {HStack, VStack} from '@astryxdesign/core/Layout';
import {NumberInput} from '@astryxdesign/core/NumberInput';
import {Section} from '@astryxdesign/core/Section';
import {Switch} from '@astryxdesign/core/Switch';
import {Heading, Text} from '@astryxdesign/core/Text';
import {XMarkIcon} from '@heroicons/react/24/outline';
import {labelOf, numericKeys, objectOf, titleOf, type Item, type Json, type Scene} from './scene';

interface Props {
  scene: Scene;
  item: Item;
  onEdit: (change: (draft: Scene) => void) => void;
  onClose: () => void;
}

/** Steps that suit each kind of number. */
const stepFor = (key: string) =>
  key.endsWith('_deg') ? 1 : key === 'count' ? 1 : key === 'n' || key === 'k' || key === 'fill_factor' ? 0.01 : 0.1;

export function Inspector({scene, item, onEdit, onClose}: Props) {
  const o = objectOf(scene, item);
  const shape = (o.shape ?? null) as Json | null;
  const material = (o.material ?? null) as Json | null;

  const field = (path: (draft: Scene) => Json, key: string, value: number) => {
    const {label, unit} = labelOf(key);
    return (
      <NumberInput
        key={key}
        label={unit ? `${label} (${unit})` : label}
        value={value}
        step={stepFor(key)}
        min={key === 'count' ? 1 : key === 'n' ? 0.1 : undefined}
        onChange={(v) => onEdit((draft) => void (path(draft)[key] = key === 'count' ? Math.round(v) : v))}
        size="sm"
      />
    );
  };

  const own = (draft: Scene) => objectOf(draft, item);
  const ownKeys = numericKeys(o);
  const materialNote =
    material?.type === 'pec'
      ? 'Perfect conductor'
      : material?.type === 'dispersive'
        ? `Dispersive: ${String(material.preset ?? 'custom')}`
        : null;

  return (
    <Section variant="transparent" padding={4}>
      <VStack gap={4}>
        <HStack gap={2} vAlign="center" hAlign="between">
          <Heading level={3}>{titleOf(scene, item)}</Heading>
          <Button label="Deselect" variant="ghost" size="sm" isIconOnly icon={<Icon icon={XMarkIcon} size="sm" />} onClick={onClose} />
        </HStack>
        <Switch
          label="Enabled"
          size="sm"
          value={o.enabled !== false}
          onChange={(on) => onEdit((draft) => void (own(draft).enabled = on))}
        />
        <div className="field-grid">{ownKeys.map((k) => field(own, k, Number(o[k])))}</div>
        {material && material.type === 'dielectric' && (
          <div className="field-grid">
            {numericKeys(material).map((k) => field((d) => own(d).material as Json, k, Number(material[k])))}
          </div>
        )}
        {materialNote && <Text type="supporting">{materialNote}</Text>}
        {shape && (
          <VStack gap={3}>
            <Text type="label" weight="semibold">
              Shape
            </Text>
            <div className="field-grid">
              {numericKeys(shape).map((k) => field((d) => own(d).shape as Json, k, Number(shape[k])))}
            </div>
          </VStack>
        )}
      </VStack>
    </Section>
  );
}
