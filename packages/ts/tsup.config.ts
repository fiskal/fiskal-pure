import { defineConfig } from 'tsup';

export default defineConfig([
  // Core + react entry
  {
    entry: { index: 'src/index.ts' },
    format: ['esm', 'cjs'],
    dts: true,
    sourcemap: true,
    clean: true,
    splitting: false,
    treeshake: true,
    target: 'esnext',
    external: ['react', 'react-dom'],
  },
  // Adapter entries
  {
    entry: {
      'adapters/memory': 'src/adapters/memory.ts',
      'adapters/firestore': 'src/adapters/firestore.ts',
      'adapters/gun': 'src/adapters/gun.ts',
    },
    format: ['esm', 'cjs'],
    dts: true,
    sourcemap: true,
    splitting: false,
    treeshake: true,
    target: 'esnext',
    external: ['firebase', 'firebase/app', 'firebase/firestore', 'gun'],
  },
  // Test utilities entry
  {
    entry: { 'test/index': 'src/test/index.ts' },
    format: ['esm', 'cjs'],
    dts: true,
    sourcemap: true,
    splitting: false,
    treeshake: true,
    target: 'esnext',
    external: ['react', 'react-dom'],
  },
]);
