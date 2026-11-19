import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';

// The viewer is served at fringe.lprsrts.com/web/ from the site's public folder.
export default defineConfig({
  base: '/web/',
  plugins: [react()],
  worker: {format: 'es'},
  build: {
    outDir: '../site/public/web',
    emptyOutDir: true,
    target: 'es2022',
    // One app chunk of about 290 kB gzipped, most of it Astryx; the solver's
    // 2.5 MB wasm dominates the download either way.
    chunkSizeWarningLimit: 1200,
  },
});
