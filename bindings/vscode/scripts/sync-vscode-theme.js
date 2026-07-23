#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const THEMES_DIR = path.join(__dirname, "..", "themes");
const OUTPUT_FILE = path.join(THEMES_DIR, "current-snapshot.json");

const VSCODE_BASE = "/usr/share/code/resources/app";
const BUILTIN_THEMES_DIR = path.join(VSCODE_BASE, "extensions", "theme-defaults", "themes");
const EXTENSION_THEME_BASES = [
  "/usr/share/code/resources/app/extensions",
  path.join(process.env.HOME || "/root", ".vscode", "extensions"),
  path.join(process.env.HOME || "/root", ".vscode-oss", "extensions"),
];

const SETTINGS_PATHS = [
  path.join(process.env.HOME || "/root", ".config", "Code", "User", "settings.json"),
  path.join(process.env.HOME || "/root", ".config", "Code - OSS", "User", "settings.json"),
  path.join(process.env.HOME || "/root", ".config", "VSCodium", "User", "settings.json"),
];

function resolveTheme(themePath) {
  const theme = JSON.parse(fs.readFileSync(themePath, "utf8"));
  if (!theme.include) return theme;
  const includePath = path.join(path.dirname(themePath), theme.include);
  const parent = resolveTheme(includePath);
  const merged = { name: theme.name || parent.name, type: theme.type || parent.type };
  if (parent.colors || theme.colors)
    merged.colors = Object.assign({}, parent.colors || {}, theme.colors || {});
  if (parent.tokenColors || theme.tokenColors)
    merged.tokenColors = [].concat(parent.tokenColors || [], theme.tokenColors || {});
  return merged;
}

function findThemeFile(themeName, extensionsDir) {
  if (!fs.existsSync(extensionsDir)) return null;
  const dirs = fs.readdirSync(extensionsDir);
  for (const dir of dirs) {
    const pkgPath = path.join(extensionsDir, dir, "package.json");
    if (!fs.existsSync(pkgPath)) continue;
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
      const themes = pkg.contributes?.themes || [];
      for (const t of themes) {
        if (t.id === themeName || t.label === themeName) {
          const themePath = path.join(extensionsDir, dir, t.path);
          if (fs.existsSync(themePath)) return themePath;
        }
      }
    } catch (_) { /* skip malformed packages */ }
  }
  return null;
}

function findThemeInBuiltins(themeName) {
  if (!fs.existsSync(BUILTIN_THEMES_DIR)) return null;
  const files = fs.readdirSync(BUILTIN_THEMES_DIR).filter(f => f.endsWith(".json"));
  for (const file of files) {
    try {
      const theme = JSON.parse(fs.readFileSync(path.join(BUILTIN_THEMES_DIR, file), "utf8"));
      if (theme.name === themeName) return path.join(BUILTIN_THEMES_DIR, file);
    } catch (_) { /* skip */ }
  }
  return null;
}

function findCurrentThemePath(themeName) {
  let found = null;

  // Check if this is a local theme (milk-tea-dark)
  const localName = themeName.toLowerCase();
  const localFiles = fs.readdirSync(THEMES_DIR).filter(f => f.endsWith(".json") && f !== path.basename(OUTPUT_FILE));
  for (const file of localFiles) {
    try {
      const theme = JSON.parse(fs.readFileSync(path.join(THEMES_DIR, file), "utf8"));
      if ((theme.name || "").toLowerCase() === localName) {
        found = path.join(THEMES_DIR, file);
        break;
      }
    } catch (_) { /* skip */ }
  }

  // Check built-in VS Code themes
  if (!found) found = findThemeInBuiltins(themeName);

  // Check installed extensions
  if (!found) {
    for (const extDir of EXTENSION_THEME_BASES) {
      found = findThemeFile(themeName, extDir);
      if (found) break;
    }
  }

  return found;
}

function parseSettingsFile(filePath) {
  if (!fs.existsSync(filePath)) return null;
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    // Strip line comments and trailing commas for JSONC support
    const stripped = raw
      .split("\n")
      .map(line => line.replace(/\/\/.*$/, "").replace(/\/\*.*\*\//g, ""))
      .join("\n")
      .replace(/,\s*([}\]])/g, "$1");
    return JSON.parse(stripped);
  } catch (_) {
    return null;
  }
}

function getActiveThemeName() {
  for (const p of SETTINGS_PATHS) {
    const settings = parseSettingsFile(p);
    if (settings && settings["workbench.colorTheme"])
      return settings["workbench.colorTheme"];
  }
  return null;
}

function main() {
  const args = process.argv.slice(2);
  const pullFromVSCode = args.includes("--pull");
  const dryRun = args.includes("--dry-run");
  const themeOverride = args.find(a => !a.startsWith("--"));

  const themeName = themeOverride || getActiveThemeName();
  if (!themeName) {
    process.stderr.write("No active VS Code theme found. Pass a theme name as argument.\n");
    process.stderr.write("Usage: node scripts/sync-vscode-theme.js [theme-name] [--pull] [--dry-run]\n");
    process.stderr.write("  --pull   Copy from VS Code installation (updates local copy)\n");
    process.stderr.write("  --dry-run  Output to a separate file without overwriting current-snapshot.json\n");
    process.exit(1);
  }

  let themePath = null;

  if (pullFromVSCode) {
    themePath = findThemeInBuiltins(themeName);
    if (themePath) {
      // Copy the official theme file to our themes directory
      const destName = "pulled-" + path.basename(themePath);
      const destPath = path.join(THEMES_DIR, destName);
      const theme = JSON.parse(fs.readFileSync(themePath, "utf8"));

      // Rewrite include paths to point to our local copies
      if (theme.include) {
        const baseName = path.basename(theme.include);
        const existing = path.join(THEMES_DIR, baseName);
        if (fs.existsSync(existing)) {
          theme.include = "./" + baseName;
        } else {
          process.stderr.write(`Warning: include target ${baseName} not found in local themes, remove include chain\n`);
        }
      }

      // Also copy the include chain files if they exist in builtins
      if (theme.include) {
        const includePath = path.join(path.dirname(themePath), theme.include);
        if (fs.existsSync(includePath)) {
          const includeDest = path.join(THEMES_DIR, path.basename(theme.include));
          if (!fs.existsSync(includeDest)) {
            fs.writeFileSync(includeDest, fs.readFileSync(includePath, "utf8"));
            process.stderr.write(`Copied include: ${path.basename(theme.include)} from VS Code\n`);
          }
        }
      }

      fs.writeFileSync(destPath, JSON.stringify(theme, null, 2));
      process.stderr.write(`Pulled official theme to ${destPath}\n`);
      themePath = destPath;
    } else {
      process.stderr.write(`Theme "${themeName}" not found in built-in VS Code themes.\n`);
      process.exit(1);
    }
  } else {
    themePath = findCurrentThemePath(themeName);
  }

  if (!themePath) {
    process.stderr.write(`Theme "${themeName}" not found.\n`);
    process.stderr.write(`Checked:\n`);
    process.stderr.write(`  - ${THEMES_DIR} (local)\n`);
    process.stderr.write(`  - ${BUILTIN_THEMES_DIR} (built-in)\n`);
    for (const ext of EXTENSION_THEME_BASES)
      process.stderr.write(`  - ${ext} (extensions)\n`);
    process.exit(1);
  }

  console.log(`Theme "${themeName}" found at ${themePath}`);
  const resolved = resolveTheme(themePath);
  delete resolved.include;

  const outputPath = dryRun ? path.join(THEMES_DIR, `resolved-${path.basename(themePath)}`) : OUTPUT_FILE;

  fs.writeFileSync(outputPath, JSON.stringify(resolved, null, 2));
  console.log(`Resolved theme written to ${outputPath}`);
  console.log(`  tokenColors: ${resolved.tokenColors?.length || 0} rules`);
  console.log(`  colors: ${Object.keys(resolved.colors || {}).length} UI colors`);
  console.log(`  name: ${resolved.name}`);
}

main();
