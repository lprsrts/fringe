import type {Issue} from './solver';

export interface StatusMessage {
  severity: 'error' | 'warning' | 'info';
  text: string;
}

const RANK = {error: 0, warning: 1, info: 2} as const;

/** The wavelength slider's lower end; advice below it couldn't be followed. */
const MIN_ADVISED_WAVELENGTH_UM = 0.3;
/** The core prints sizes to 4 decimals, so each printed value is off by up to this. */
const PRINT_SLACK_UM = 5e-5;

/** "Radius must be at least 0.0855 µm (got 0.076 µm)" -> [0.0855, 0.076] */
function minAndGot(message: string): [number, number] | null {
  const m = message.match(/at least ([\d.]+) µm \(got ([\d.]+) µm\)/);
  return m ? [Number(m[1]), Number(m[2])] : null;
}

/** "elements[12].shape.radius_um" -> "12"; other paths count as themselves. */
function partOf(path: string): string {
  return path.match(/^elements\[(\d+)\]/)?.[1] ?? path;
}

/**
 * Check issues as status messages. Identical messages are shown once with a
 * count, so a lattice of 176 rods that are all too small gives one line, not
 * 176.
 *
 * Every size and gap must be at least 0.05 λ in the background, so a scene
 * that worked can fail when the wavelength goes up. When `wavelengthUm` is
 * given (the wavelength can be changed, as in the simulator), the message for
 * those parts also says the longest wavelength they still allow, if that is
 * one the slider can reach.
 */
export function groupIssues(issues: Issue[], wavelengthUm?: number): StatusMessage[] {
  const groups = new Map<string, {issue: Issue; parts: Set<string>; count: number}>();
  for (const issue of issues) {
    const key = `${issue.severity}|${issue.code ?? ''}|${issue.message}`;
    const g = groups.get(key) ?? {issue, parts: new Set<string>(), count: 0};
    g.parts.add(partOf(issue.path));
    g.count++;
    groups.set(key, g);
  }

  // The longest wavelength every too-small part allows, worked out on the safe
  // side of the printed rounding (minimum rounded up, size rounded down).
  const tooSmallParts = new Set<string>();
  let limit = Infinity;
  if (wavelengthUm && wavelengthUm > 0) {
    for (const {issue, parts} of groups.values()) {
      if (issue.code !== 'too_small' || issue.severity !== 'error') continue;
      const sizes = minAndGot(issue.message);
      if (!sizes) continue;
      const [min, got] = sizes;
      limit = Math.min(limit, (wavelengthUm * Math.max(0, got - PRINT_SLACK_UM)) / (min + PRINT_SLACK_UM));
      parts.forEach((p) => tooSmallParts.add(p));
    }
  }
  const advised = Math.floor(limit * 100) / 100;
  const advise =
    tooSmallParts.size > 0 && advised >= MIN_ADVISED_WAVELENGTH_UM && advised < (wavelengthUm ?? 0);

  const out: (StatusMessage & {rank: number})[] = [];
  for (const {issue, parts, count} of groups.values()) {
    const n = issue.path.startsWith('elements[') ? parts.size : count;
    const suffix = n > 1 ? (issue.path.startsWith('elements[') ? ` (${n} parts)` : ` (×${n})`) : '';
    out.push({severity: issue.severity, text: issue.message + suffix, rank: RANK[issue.severity]});
  }
  if (advise) {
    const which = tooSmallParts.size === 1 ? '1 part is' : `${tooSmallParts.size} parts are`;
    out.push({
      severity: 'error',
      // Short enough for one line on a phone; the size messages say what to enlarge instead.
      text: `${which} too small for ${Number(wavelengthUm!.toFixed(3))} µm. Use ${advised} µm or less.`,
      rank: -1,
    });
  }
  return out.sort((a, b) => a.rank - b.rank).map(({severity, text}) => ({severity, text}));
}
