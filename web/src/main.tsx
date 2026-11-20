import '@astryxdesign/core/reset.css';
import '@astryxdesign/core/astryx.css';
import '@astryxdesign/theme-neutral/theme.css';
import './app.css';

import {StrictMode} from 'react';
import {createRoot} from 'react-dom/client';
import {Theme} from '@astryxdesign/core/theme';
import {fringeTheme} from './theme';
import {App} from './App';
import {ErrorBoundary} from './ErrorBoundary';

document.documentElement.dataset.astryxTheme = 'neutral';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Theme theme={fringeTheme}>
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </Theme>
  </StrictMode>,
);
