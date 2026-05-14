#!/usr/bin/env node

const esbuild = require('esbuild');
const fs = require('node:fs');
const path = require('node:path');

const VSCODE_ROOT = path.resolve(__dirname, '..');
const DIST_DIR = path.join(VSCODE_ROOT, 'dist');
const ENTRYPOINT = path.join(VSCODE_ROOT, 'src', 'extension.ts');
const OUTFILE = path.join(DIST_DIR, 'extension.js');

const buildOptions = {
  entryPoints: [ENTRYPOINT],
  outfile: OUTFILE,
  bundle: true,
  format: 'cjs',
  platform: 'node',
  target: 'node18',
  external: ['vscode'],
  logLevel: 'info',
  legalComments: 'none',
};

function cleanDist() {
  fs.rmSync(DIST_DIR, { recursive: true, force: true });
  fs.mkdirSync(DIST_DIR, { recursive: true });
}

async function run() {
  const watch = process.argv.includes('--watch');
  cleanDist();

  const options = {
    ...buildOptions,
    minify: !watch,
    sourcemap: watch,
  };

  if (watch) {
    const context = await esbuild.context(options);
    await context.watch();
    process.stdout.write('Watching extension bundle changes...\n');
    return;
  }

  await esbuild.build(options);
}

run().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack || error.message : String(error)}\n`);
  process.exit(1);
});
