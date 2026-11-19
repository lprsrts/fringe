// Fringe's look on Astryx: neutral's graphite surfaces and type, with the
// fringe amber of the site and the app icon as the one accent. The accent is
// set as tokens rather than a colour seed, because a seed also tints every
// neutral towards it. The amber is darker in light mode so text and focus
// rings keep their contrast, and text on it is near-black in dark mode.
import {defineTheme} from '@astryxdesign/core/theme';
import {neutralTheme} from '@astryxdesign/theme-neutral/built';

export const fringeTheme = defineTheme({
  name: 'fringe',
  extends: neutralTheme,
  tokens: {
    '--color-accent': ['#8a5a00', '#f3c623'],
    '--color-on-accent': ['#ffffff', '#1c1600'],
    '--color-background-body': ['#f3f4f5', '#0b0d0f'],
    '--color-background-surface': ['#ffffff', '#121417'],
  },
});
