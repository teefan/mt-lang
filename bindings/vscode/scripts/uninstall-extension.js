#!/usr/bin/env node

const { spawnSync } = require('node:child_process');

const EXTENSION_ID = 'milk-tea-lang.milk-tea-lang';

function fail(message, exitCode = 1) {
  process.stderr.write(`${message}\n`);
  process.exit(exitCode);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    ...options,
  });

  if (result.error) {
    fail(result.error.message);
  }

  return result;
}

function main() {
  const listResult = run('code', ['--list-extensions'], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  if (listResult.status !== 0) {
    fail(listResult.stderr.trim() || '`code --list-extensions` failed.', listResult.status || 1);
  }

  const installedExtensions = new Set(
    listResult.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
  );

  if (!installedExtensions.has(EXTENSION_ID)) {
    process.stdout.write(`Extension '${EXTENSION_ID}' is not installed; skipping uninstall.\n`);
    return;
  }

  const uninstallResult = run('code', ['--uninstall-extension', EXTENSION_ID], {
    stdio: 'inherit',
  });

  if (uninstallResult.status !== 0) {
    process.exit(uninstallResult.status || 1);
  }
}

main();
