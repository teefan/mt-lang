#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { parse: parseJsonc } = require('jsonc-parser');

const oniguruma = require('vscode-oniguruma');
const { Registry, parseRawGrammar, INITIAL } = require('vscode-textmate');

const TOKEN_TYPE_MAP = {
  0: 'other',
  1: 'comment',
  2: 'string',
  3: 'regex'
};

const FALLBACK_SEMANTIC_TOKEN_SCOPE_MAP = [
  { selector: 'namespace', scopes: ['entity.name.namespace'] },
  { selector: 'type', scopes: ['entity.name.type', 'support.type'] },
  { selector: 'class', scopes: ['entity.name.type.class', 'entity.name.type'] },
  { selector: 'enum', scopes: ['entity.name.type.enum', 'entity.name.type'] },
  { selector: 'interface', scopes: ['entity.name.type.interface', 'entity.name.type'] },
  { selector: 'struct', scopes: ['storage.type.struct', 'entity.name.type.struct', 'entity.name.type'] },
  { selector: 'typeParameter', scopes: ['entity.name.type.parameter', 'entity.name.type'] },
  { selector: 'parameter', scopes: ['variable.parameter'] },
  { selector: 'variable', scopes: ['variable.other.readwrite', 'variable.other'] },
  { selector: 'variable.readonly', scopes: ['variable.other.constant', 'variable.other'] },
  { selector: 'variable.defaultLibrary', scopes: ['support.variable', 'variable.other'] },
  { selector: 'property', scopes: ['variable.other.property', 'variable.other'] },
  { selector: 'property.readonly', scopes: ['variable.other.constant.property', 'variable.other.constant', 'variable.other.property'] },
  { selector: 'property.defaultLibrary', scopes: ['support.variable.property', 'support.variable', 'variable.other.property'] },
  { selector: 'enumMember', scopes: ['variable.other.enummember', 'variable.other.constant'] },
  { selector: 'event', scopes: ['variable.other.event', 'variable.other'] },
  { selector: 'function', scopes: ['entity.name.function', 'support.function'] },
  { selector: 'function.defaultLibrary', scopes: ['support.function', 'entity.name.function'] },
  { selector: 'method', scopes: ['entity.name.function.member', 'entity.name.function', 'support.function'] },
  { selector: 'method.defaultLibrary', scopes: ['support.function', 'entity.name.function.member', 'entity.name.function'] },
  { selector: 'macro', scopes: ['entity.name.function.macro', 'entity.name.function'] },
  { selector: 'keyword', scopes: ['keyword'] },
  { selector: 'modifier', scopes: ['storage.modifier', 'keyword'] },
  { selector: 'comment', scopes: ['comment'] },
  { selector: 'string', scopes: ['string'] },
  { selector: 'number', scopes: ['constant.numeric'] },
  { selector: 'regexp', scopes: ['string.regexp', 'source.regexp'] },
  { selector: 'operator', scopes: ['keyword.operator'] },
  { selector: 'decorator', scopes: ['entity.name.decorator', 'entity.name.function'] }
];

const FONT_STYLE = {
  NONE: 0,
  ITALIC: 1,
  BOLD: 2,
  UNDERLINE: 4,
  STRIKETHROUGH: 8
};

function usage() {
  console.error(
    [
      'Usage:',
      '  node scripts/snapshot-textmate.js --input <file.mt> [options]',
      '',
      'Options:',
      '  --theme-name <name>     Theme label/id (default: "Dark 2026")',
      '  --theme-file <path>     Exact theme json path (overrides --theme-name)',
      '  --grammar <path>        tmLanguage json path',
      '  --semantic-overlay <m>  none|compiler (default: none)',
      '  --json-out <path>       Output json snapshot path',
      '  --html-out <path>       Output html snapshot path',
      '  --help                  Show this help',
      '',
      'Example:',
      '  node scripts/snapshot-textmate.js --input ../../examples/sdl3/renderer/color_mods.mt'
    ].join('\n')
  );
}

function parseArgs(argv) {
  const args = {
    themeName: 'Dark 2026',
    grammarPath: path.resolve(__dirname, '..', 'syntaxes', 'milk-tea.tmLanguage.json'),
    semanticOverlay: 'none'
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      args.help = true;
      continue;
    }
    if (arg.startsWith('--input=')) {
      args.inputPath = arg.slice('--input='.length);
      continue;
    }
    if (arg === '--input') {
      args.inputPath = argv[++i];
      continue;
    }
    if (arg.startsWith('--theme-name=')) {
      args.themeName = arg.slice('--theme-name='.length);
      continue;
    }
    if (arg === '--theme-name') {
      args.themeName = argv[++i];
      continue;
    }
    if (arg.startsWith('--theme-file=')) {
      args.themeFile = arg.slice('--theme-file='.length);
      continue;
    }
    if (arg === '--theme-file') {
      args.themeFile = argv[++i];
      continue;
    }
    if (arg.startsWith('--grammar=')) {
      args.grammarPath = arg.slice('--grammar='.length);
      continue;
    }
    if (arg === '--grammar') {
      args.grammarPath = argv[++i];
      continue;
    }
    if (arg.startsWith('--semantic-overlay=')) {
      args.semanticOverlay = arg.slice('--semantic-overlay='.length);
      continue;
    }
    if (arg === '--semantic-overlay') {
      args.semanticOverlay = argv[++i];
      continue;
    }
    if (arg.startsWith('--json-out=')) {
      args.jsonOut = arg.slice('--json-out='.length);
      continue;
    }
    if (arg === '--json-out') {
      args.jsonOut = argv[++i];
      continue;
    }
    if (arg.startsWith('--html-out=')) {
      args.htmlOut = arg.slice('--html-out='.length);
      continue;
    }
    if (arg === '--html-out') {
      args.htmlOut = argv[++i];
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return args;
}

function ensureAbs(p) {
  if (!p) {
    return p;
  }
  return path.isAbsolute(p) ? p : path.resolve(process.cwd(), p);
}

function loadJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function loadJsoncFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }

  const raw = fs.readFileSync(filePath, 'utf8');
  const errors = [];
  const parsed = parseJsonc(raw, errors, {
    allowTrailingComma: true,
    disallowComments: false
  });

  if (errors.length > 0 || !parsed || typeof parsed !== 'object') {
    return null;
  }

  return parsed;
}

function getNestedSetting(obj, dottedKey) {
  if (!obj || typeof obj !== 'object') {
    return undefined;
  }

  if (Object.prototype.hasOwnProperty.call(obj, dottedKey)) {
    return obj[dottedKey];
  }

  const parts = dottedKey.split('.');
  let cur = obj;
  for (const part of parts) {
    if (!cur || typeof cur !== 'object' || !Object.prototype.hasOwnProperty.call(cur, part)) {
      return undefined;
    }
    cur = cur[part];
  }
  return cur;
}

function candidateSettingsPaths(inputPath) {
  const home = os.homedir();
  const paths = [
    path.join(home, '.config', 'Code', 'User', 'settings.json'),
    path.join(home, '.config', 'Code - OSS', 'User', 'settings.json'),
    path.join(home, '.vscode', 'settings.json'),
    path.join(home, '.vscode-oss', 'settings.json')
  ];

  let cur = path.dirname(path.resolve(inputPath));
  while (true) {
    const candidate = path.join(cur, '.vscode', 'settings.json');
    paths.push(candidate);

    const parent = path.dirname(cur);
    if (parent === cur) {
      break;
    }
    cur = parent;
  }

  return Array.from(new Set(paths));
}

function normalizeThemeNames(themeInfo, resolvedTheme, requestedThemeName) {
  return new Set(
    [
      requestedThemeName,
      resolvedTheme && resolvedTheme.name,
      themeInfo && themeInfo.label,
      themeInfo && themeInfo.id,
    ]
      .filter((name) => typeof name === 'string' && name.trim().length > 0)
      .map((name) => name.trim().toLowerCase())
  );
}

function appendSemanticRules(ruleList, valueMap, startOrder) {
  if (!valueMap || typeof valueMap !== 'object') {
    return startOrder;
  }

  let order = startOrder;
  for (const [selector, value] of Object.entries(valueMap)) {
    if (typeof selector !== 'string' || selector.trim().length === 0) {
      continue;
    }
    ruleList.push({ selector: selector.trim(), value, order });
    order += 1;
  }
  return order;
}

function collectSettingsSemanticRules(settingsObj, themeNames, startOrder) {
  const result = {
    rules: [],
    order: startOrder,
    enabled: undefined
  };

  const customizations = getNestedSetting(settingsObj, 'editor.semanticTokenColorCustomizations');
  if (!customizations || typeof customizations !== 'object') {
    return result;
  }

  if (typeof customizations.enabled === 'boolean') {
    result.enabled = customizations.enabled;
  }

  result.order = appendSemanticRules(result.rules, customizations.rules, result.order);

  for (const [rawKey, value] of Object.entries(customizations)) {
    const match = /^\[(.+)\]$/.exec(rawKey);
    if (!match || !value || typeof value !== 'object') {
      continue;
    }

    const themeKey = match[1].trim().toLowerCase();
    if (!themeNames.has(themeKey)) {
      continue;
    }

    if (typeof value.enabled === 'boolean') {
      result.enabled = value.enabled;
    }
    result.order = appendSemanticRules(result.rules, value.rules, result.order);
  }

  return result;
}

function loadMergedSemanticSettingRules(inputPath, themeInfo, resolvedTheme, requestedThemeName) {
  const themeNames = normalizeThemeNames(themeInfo, resolvedTheme, requestedThemeName);
  const sources = [];
  const merged = [];
  let order = 0;
  let enabled = undefined;

  const settingsPaths = candidateSettingsPaths(inputPath);
  for (const settingsPath of settingsPaths) {
    const parsed = loadJsoncFile(settingsPath);
    if (!parsed) {
      continue;
    }

    const next = collectSettingsSemanticRules(parsed, themeNames, order);
    if (next.rules.length > 0 || typeof next.enabled === 'boolean') {
      sources.push(settingsPath);
    }
    if (typeof next.enabled === 'boolean') {
      enabled = next.enabled;
    }
    order = next.order;
    merged.push(...next.rules);
  }

  return {
    rules: merged,
    enabled,
    sources
  };
}

function mergeSemanticRuleSets(baseRules, overrideRules) {
  const bySelector = new Map();

  (Array.isArray(baseRules) ? baseRules : []).forEach((rule) => {
    if (rule && typeof rule.selector === 'string') {
      bySelector.set(rule.selector, rule);
    }
  });

  (Array.isArray(overrideRules) ? overrideRules : []).forEach((rule) => {
    if (!rule || typeof rule.selector !== 'string') {
      return;
    }
    if (bySelector.has(rule.selector)) {
      bySelector.delete(rule.selector);
    }
    bySelector.set(rule.selector, rule);
  });

  let order = 0;
  return Array.from(bySelector.values()).map((rule) => {
    const next = { ...rule, order };
    order += 1;
    return next;
  });
}

function candidateVsCodeRuntimeFiles() {
  return [
    '/opt/visual-studio-code/resources/app/out/vs/workbench/workbench.desktop.main.js',
    '/usr/share/code/resources/app/out/vs/workbench/workbench.desktop.main.js',
    '/usr/lib/code/resources/app/out/vs/workbench/workbench.desktop.main.js',
    '/opt/visual-studio-code/resources/app/out/vs/workbench/workbench.web.main.js',
    '/usr/share/code/resources/app/out/vs/workbench/workbench.web.main.js',
    '/usr/lib/code/resources/app/out/vs/workbench/workbench.web.main.js'
  ];
}

function readBracketedArrayLiteral(source, startIndex) {
  if (startIndex < 0 || source[startIndex] !== '[') {
    return null;
  }

  let i = startIndex;
  let depth = 0;
  let inString = false;
  let escapeNext = false;

  while (i < source.length) {
    const ch = source[i];

    if (inString) {
      if (escapeNext) {
        escapeNext = false;
      } else if (ch === '\\') {
        escapeNext = true;
      } else if (ch === '"') {
        inString = false;
      }
      i += 1;
      continue;
    }

    if (ch === '"') {
      inString = true;
      i += 1;
      continue;
    }

    if (ch === '[') {
      depth += 1;
      i += 1;
      continue;
    }

    if (ch === ']') {
      depth -= 1;
      i += 1;
      if (depth === 0) {
        return {
          text: source.slice(startIndex, i),
          endIndex: i
        };
      }
      continue;
    }

    i += 1;
  }

  return null;
}

function extractScopesFromMatrixLiteral(matrixText) {
  const scopes = [];
  const re = /"([^"\\]*(?:\\.[^"\\]*)*)"/g;
  let match;
  while ((match = re.exec(matrixText))) {
    const raw = match[1];
    const unescaped = raw.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    if (!scopes.includes(unescaped)) {
      scopes.push(unescaped);
    }
  }
  return scopes;
}

function extractSemanticScopeMapFromRuntimeJs(sourceText) {
  const entries = [];
  const seen = new Set();
  const callRe = /\b([ie])\("([A-Za-z][A-Za-z0-9_.]*)"/g;
  let match;

  while ((match = callRe.exec(sourceText))) {
    const selector = match[2];
    const callIndex = match.index;
    const matrixStart = sourceText.indexOf('[[', callRe.lastIndex);
    if (matrixStart < 0 || matrixStart - callIndex > 400) {
      continue;
    }

    const matrix = readBracketedArrayLiteral(sourceText, matrixStart);
    if (!matrix) {
      continue;
    }

    const scopes = extractScopesFromMatrixLiteral(matrix.text).filter((scope) => scope.includes('.'));
    if (scopes.length === 0) {
      continue;
    }

    const key = `${selector}@@${scopes.join('|')}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    entries.push({ selector, scopes });
  }

  return entries;
}

function loadBuiltinSemanticScopeMap() {
  let best = [];
  let sourcePath = null;

  for (const filePath of candidateVsCodeRuntimeFiles()) {
    if (!fs.existsSync(filePath)) {
      continue;
    }

    let text;
    try {
      text = fs.readFileSync(filePath, 'utf8');
    } catch (_err) {
      continue;
    }

    const extracted = extractSemanticScopeMapFromRuntimeJs(text);
    if (extracted.length > best.length) {
      best = extracted;
      sourcePath = filePath;
    }
  }

  if (best.length > 0) {
    return {
      source: sourcePath,
      entries: best
    };
  }

  return {
    source: 'fallback-static',
    entries: FALLBACK_SEMANTIC_TOKEN_SCOPE_MAP
  };
}

function loadNlsForPackage(packageJsonPath) {
  const dir = path.dirname(packageJsonPath);
  const nlsPath = path.join(dir, 'package.nls.json');
  if (!fs.existsSync(nlsPath)) {
    return {};
  }
  try {
    return loadJson(nlsPath);
  } catch (_err) {
    return {};
  }
}

function resolveLocalizedLabel(label, nlsMap) {
  if (typeof label !== 'string') {
    return label;
  }
  const match = /^%(.+)%$/.exec(label);
  if (!match) {
    return label;
  }
  return nlsMap[match[1]] || label;
}

function candidateThemeExtensionDirs() {
  const home = os.homedir();
  return [
    '/opt/visual-studio-code/resources/app/extensions',
    '/usr/share/code/resources/app/extensions',
    '/usr/lib/code/resources/app/extensions',
    path.join(home, '.vscode', 'extensions'),
    path.join(home, '.vscode-oss', 'extensions')
  ];
}

function findThemeByName(themeName) {
  const dirs = candidateThemeExtensionDirs().filter((d) => fs.existsSync(d));
  const lc = themeName.toLowerCase();

  for (const root of dirs) {
    const entries = fs.readdirSync(root, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) {
        continue;
      }
      const extPath = path.join(root, entry.name);
      const pkgPath = path.join(extPath, 'package.json');
      if (!fs.existsSync(pkgPath)) {
        continue;
      }
      let pkg;
      try {
        pkg = loadJson(pkgPath);
      } catch (_err) {
        continue;
      }
      const nls = loadNlsForPackage(pkgPath);
      const themes = pkg.contributes && pkg.contributes.themes;
      if (!Array.isArray(themes)) {
        continue;
      }
      for (const theme of themes) {
        const id = (theme.id || '').toLowerCase();
        const resolvedLabel = resolveLocalizedLabel(theme.label || '', nls);
        const label = resolvedLabel.toLowerCase();
        if (id !== lc && label !== lc) {
          continue;
        }
        const resolvedPath = path.resolve(extPath, theme.path);
        if (!fs.existsSync(resolvedPath)) {
          continue;
        }
        return {
          path: resolvedPath,
          id: theme.id || null,
          label: resolvedLabel || theme.label || null,
          uiTheme: theme.uiTheme || null,
          extensionPath: extPath
        };
      }
    }
  }

  return null;
}

async function loadOniguruma() {
  const wasmPath = require.resolve('vscode-oniguruma/release/onig.wasm');
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmSlice = wasmBuffer.buffer.slice(
    wasmBuffer.byteOffset,
    wasmBuffer.byteOffset + wasmBuffer.byteLength
  );
  await oniguruma.loadWASM(wasmSlice);
}

function mergeThemeLayers(base, overlay) {
  const baseSemantic = Array.isArray(base.semanticTokenColorRules) ? base.semanticTokenColorRules : [];
  const overlaySemantic = Array.isArray(overlay.semanticTokenColorRules) ? overlay.semanticTokenColorRules : [];
  const semanticBySelector = new Map();

  baseSemantic.forEach((rule) => semanticBySelector.set(rule.selector, rule));
  overlaySemantic.forEach((rule) => {
    if (semanticBySelector.has(rule.selector)) {
      semanticBySelector.delete(rule.selector);
    }
    semanticBySelector.set(rule.selector, rule);
  });

  return {
    name: overlay.name || base.name,
    type: overlay.type || base.type,
    colors: {
      ...(base.colors || {}),
      ...(overlay.colors || {})
    },
    tokenColors: [
      ...(Array.isArray(base.tokenColors) ? base.tokenColors : []),
      ...(Array.isArray(overlay.tokenColors) ? overlay.tokenColors : [])
    ],
    semanticTokenColorRules: Array.from(semanticBySelector.values())
  };
}

function normalizeSemanticTokenColors(semanticTokenColors) {
  if (!semanticTokenColors) {
    return [];
  }

  if (Array.isArray(semanticTokenColors)) {
    return semanticTokenColors
      .filter((entry) => entry && typeof entry.selector === 'string')
      .map((entry, idx) => ({ selector: entry.selector, value: entry.settings || entry.value || null, order: idx }));
  }

  if (typeof semanticTokenColors === 'object') {
    return Object.entries(semanticTokenColors).map(([selector, value], idx) => ({ selector, value, order: idx }));
  }

  return [];
}

function resolveThemeFileWithIncludes(themePath, seen = new Set()) {
  const abs = path.resolve(themePath);
  if (seen.has(abs)) {
    throw new Error(`Theme include cycle detected: ${abs}`);
  }
  seen.add(abs);

  const theme = loadJson(abs);
  let merged = {
    name: theme.name || null,
    type: theme.type || null,
    colors: theme.colors || {},
    tokenColors: Array.isArray(theme.tokenColors) ? theme.tokenColors : [],
    semanticTokenColorRules: normalizeSemanticTokenColors(theme.semanticTokenColors)
  };

  if (typeof theme.include === 'string' && theme.include.length > 0) {
    const parentPath = path.resolve(path.dirname(abs), theme.include);
    const parentMerged = resolveThemeFileWithIncludes(parentPath, seen);
    merged = mergeThemeLayers(parentMerged, merged);
  }

  return merged;
}

function parseSemanticSelector(selector) {
  if (typeof selector !== 'string' || selector.trim().length === 0) {
    return null;
  }

  const trimmed = selector.trim();
  const langSplit = trimmed.split(':');
  if (langSplit.length > 2) {
    return null;
  }

  const typeAndMods = langSplit[0].trim();
  const language = langSplit.length === 2 ? langSplit[1].trim() : null;
  if (!typeAndMods) {
    return null;
  }

  const parts = typeAndMods.split('.').map((part) => part.trim()).filter((part) => part.length > 0);
  if (parts.length === 0) {
    return null;
  }

  const tokenType = parts[0];
  const modifiers = new Set(parts.slice(1));
  return { tokenType, modifiers, language };
}

function parseSemanticRuleStyle(value) {
  if (typeof value === 'string') {
    return {
      foreground: value,
      background: null,
      fontStyle: {
        italic: null,
        bold: null,
        underline: null,
        strikethrough: null
      }
    };
  }

  if (!value || typeof value !== 'object') {
    return null;
  }

  const style = {
    foreground: typeof value.foreground === 'string' ? value.foreground : null,
    background: typeof value.background === 'string' ? value.background : null,
    fontStyle: {
      italic: null,
      bold: null,
      underline: null,
      strikethrough: null
    }
  };

  if (typeof value.bold === 'boolean') {
    style.fontStyle.bold = value.bold;
  }
  if (typeof value.italic === 'boolean') {
    style.fontStyle.italic = value.italic;
  }
  if (typeof value.underline === 'boolean') {
    style.fontStyle.underline = value.underline;
  }
  if (typeof value.strikethrough === 'boolean') {
    style.fontStyle.strikethrough = value.strikethrough;
  }

  if (typeof value.fontStyle === 'string') {
    const flags = value.fontStyle.trim().split(/\s+/).filter((flag) => flag.length > 0);
    if (flags.includes('none')) {
      style.fontStyle.italic = false;
      style.fontStyle.bold = false;
      style.fontStyle.underline = false;
      style.fontStyle.strikethrough = false;
    }
    if (flags.includes('italic')) style.fontStyle.italic = true;
    if (flags.includes('-italic')) style.fontStyle.italic = false;
    if (flags.includes('bold')) style.fontStyle.bold = true;
    if (flags.includes('-bold')) style.fontStyle.bold = false;
    if (flags.includes('underline')) style.fontStyle.underline = true;
    if (flags.includes('-underline')) style.fontStyle.underline = false;
    if (flags.includes('strikethrough')) style.fontStyle.strikethrough = true;
    if (flags.includes('-strikethrough')) style.fontStyle.strikethrough = false;
  }

  return style;
}

function semanticSelectorMatchScore(parsedSelector, semanticToken, documentLanguage) {
  if (!parsedSelector) {
    return null;
  }

  if (parsedSelector.language && parsedSelector.language !== documentLanguage) {
    return null;
  }

  if (parsedSelector.tokenType !== '*' && parsedSelector.tokenType !== semanticToken.tokenType) {
    return null;
  }

  for (const modifier of parsedSelector.modifiers) {
    if (!semanticToken.modifierSet.has(modifier)) {
      return null;
    }
  }

  const typeScore = parsedSelector.tokenType === '*' ? 0 : 1000;
  const languageScore = parsedSelector.language ? 200 : 0;
  const modifierScore = parsedSelector.modifiers.size * 10;
  return typeScore + languageScore + modifierScore;
}

function getBestSemanticRule(semanticRules, semanticToken, documentLanguage) {
  let best = null;

  semanticRules.forEach((rule, idx) => {
    const parsedSelector = parseSemanticSelector(rule.selector);
    const score = semanticSelectorMatchScore(parsedSelector, semanticToken, documentLanguage);
    if (score === null) {
      return;
    }
    const style = parseSemanticRuleStyle(rule.value);
    if (!style) {
      return;
    }

    const candidate = {
      score,
      order: typeof rule.order === 'number' ? rule.order : idx,
      style
    };

    if (!best || candidate.score > best.score || (candidate.score === best.score && candidate.order >= best.order)) {
      best = candidate;
    }
  });

  return best;
}

function getSemanticFallbackScopes(semanticToken, documentLanguage, semanticScopeMap) {
  const scopeMap = Array.isArray(semanticScopeMap) && semanticScopeMap.length > 0
    ? semanticScopeMap
    : FALLBACK_SEMANTIC_TOKEN_SCOPE_MAP;
  let best = null;

  scopeMap.forEach((entry, idx) => {
    const parsedSelector = parseSemanticSelector(entry.selector);
    const score = semanticSelectorMatchScore(parsedSelector, semanticToken, documentLanguage);
    if (score === null) {
      return;
    }

    const candidate = {
      score,
      order: idx,
      scopes: entry.scopes
    };

    if (!best || candidate.score > best.score || (candidate.score === best.score && candidate.order >= best.order)) {
      best = candidate;
    }
  });

  return best ? best.scopes : ['variable'];
}

function toRawTextMateTheme(vscodeTheme) {
  const defaultSettings = {
    foreground: (vscodeTheme.colors && vscodeTheme.colors['editor.foreground']) || undefined,
    background: (vscodeTheme.colors && vscodeTheme.colors['editor.background']) || undefined
  };

  return {
    name: vscodeTheme.name || 'snapshot-theme',
    settings: [
      { settings: defaultSettings },
      ...(Array.isArray(vscodeTheme.tokenColors) ? vscodeTheme.tokenColors : [])
    ]
  };
}

function decodeMetadata(metadata, colorMap) {
  const languageId = metadata & 0xff;
  const tokenTypeRaw = (metadata >>> 8) & 0x03;
  const fontStyleRaw = (metadata >>> 11) & 0x0f;
  const foregroundIndex = (metadata >>> 15) & 0x1ff;
  const backgroundIndex = (metadata >>> 24) & 0x1ff;

  const fontStyle = {
    italic: (fontStyleRaw & FONT_STYLE.ITALIC) !== 0,
    bold: (fontStyleRaw & FONT_STYLE.BOLD) !== 0,
    underline: (fontStyleRaw & FONT_STYLE.UNDERLINE) !== 0,
    strikethrough: (fontStyleRaw & FONT_STYLE.STRIKETHROUGH) !== 0
  };

  return {
    metadata,
    languageId,
    tokenType: TOKEN_TYPE_MAP[tokenTypeRaw] || 'unknown',
    foregroundIndex,
    foreground: colorMap[foregroundIndex] || null,
    backgroundIndex,
    background: colorMap[backgroundIndex] || null,
    fontStyle
  };
}

function parseFontStyle(fontStyle) {
  if (typeof fontStyle !== 'string' || fontStyle.trim().length === 0) {
    return {
      italic: false,
      bold: false,
      underline: false,
      strikethrough: false
    };
  }

  const flags = fontStyle.trim().split(/\s+/);
  return {
    italic: flags.includes('italic'),
    bold: flags.includes('bold'),
    underline: flags.includes('underline'),
    strikethrough: flags.includes('strikethrough')
  };
}

function mergeStyle(baseStyle, partialStyle) {
  const partialFont = partialStyle && partialStyle.fontStyle ? partialStyle.fontStyle : {};
  const mergedFontStyle = {
    italic: partialFont.italic ?? baseStyle.fontStyle.italic,
    bold: partialFont.bold ?? baseStyle.fontStyle.bold,
    underline: partialFont.underline ?? baseStyle.fontStyle.underline,
    strikethrough: partialFont.strikethrough ?? baseStyle.fontStyle.strikethrough
  };

  return {
    metadata: baseStyle.metadata,
    languageId: baseStyle.languageId,
    tokenType: baseStyle.tokenType,
    foregroundIndex: baseStyle.foregroundIndex,
    foreground: (partialStyle && partialStyle.foreground) || baseStyle.foreground,
    backgroundIndex: baseStyle.backgroundIndex,
    background: (partialStyle && partialStyle.background) || baseStyle.background,
    fontStyle: mergedFontStyle
  };
}

function normalizeScopeSelectors(scopeField) {
  if (!scopeField) {
    return [];
  }
  const raw = Array.isArray(scopeField) ? scopeField : [scopeField];
  return raw
    .flatMap((entry) => String(entry).split(','))
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function buildTokenColorRuleIndex(rawTheme) {
  const rules = [];
  const settings = Array.isArray(rawTheme.settings) ? rawTheme.settings : [];
  settings.forEach((entry, idx) => {
    const selectors = normalizeScopeSelectors(entry.scope);
    if (selectors.length === 0) {
      return;
    }
    selectors.forEach((selector) => {
      if (selector.includes(' ')) {
        return;
      }
      rules.push({
        selector,
        selectorLength: selector.length,
        order: idx,
        settings: entry.settings || {}
      });
    });
  });

  rules.sort((a, b) => {
    if (a.selectorLength !== b.selectorLength) {
      return b.selectorLength - a.selectorLength;
    }
    return b.order - a.order;
  });
  return rules;
}

function selectorMatchesScope(selector, scope) {
  return scope === selector || scope.startsWith(`${selector}.`);
}

function resolveStyleFromScope(scope, ruleIndex, baseStyle) {
  for (const rule of ruleIndex) {
    if (!selectorMatchesScope(rule.selector, scope)) {
      continue;
    }

    const partial = {
      foreground: rule.settings.foreground || null,
      background: rule.settings.background || null,
      fontStyle: parseFontStyle(rule.settings.fontStyle)
    };
    return mergeStyle(baseStyle, partial);
  }

  return baseStyle;
}

function decodeSemanticTokensData(data, legend, documentLanguage) {
  const entries = [];
  let line = 0;
  let char = 0;

  for (let i = 0; i + 4 < data.length; i += 5) {
    const deltaLine = data[i];
    const deltaStart = data[i + 1];
    const length = data[i + 2];
    const tokenTypeIdx = data[i + 3];
    const modifierBits = data[i + 4];

    line += deltaLine;
    char = deltaLine === 0 ? char + deltaStart : deltaStart;

    const tokenType = legend.tokenTypes[tokenTypeIdx] || 'variable';
    const modifiers = [];
    (legend.tokenModifiers || []).forEach((modifier, bit) => {
      if ((modifierBits & (1 << bit)) !== 0) {
        modifiers.push(modifier);
      }
    });

    const modifierSet = new Set(modifiers);
    entries.push({
      line,
      startChar: char,
      endChar: char + length,
      length,
      tokenType,
      modifiers,
      modifierSet,
      language: documentLanguage
    });
  }

  return entries;
}

function cloneTokenSegment(base, startIndex, endIndex) {
  return {
    ...base,
    startIndex,
    endIndex,
    text: base.text.slice(startIndex - base.startIndex, endIndex - base.startIndex)
  };
}

function overlaySemanticOnLineTokens(lineTokens, semanticEntries, ruleIndex, semanticRuleIndex, documentLanguage, semanticScopeMap) {
  let working = lineTokens.map((token) => ({ ...token }));

  for (const semantic of semanticEntries) {
    const next = [];
    for (const token of working) {
      if (token.endIndex <= semantic.startChar || token.startIndex >= semantic.endChar) {
        next.push(token);
        continue;
      }

      if (token.startIndex < semantic.startChar) {
        next.push(cloneTokenSegment(token, token.startIndex, semantic.startChar));
      }

      const midStart = Math.max(token.startIndex, semantic.startChar);
      const midEnd = Math.min(token.endIndex, semantic.endChar);
      const middle = cloneTokenSegment(token, midStart, midEnd);
      const semanticScopes = getSemanticFallbackScopes(semantic, documentLanguage, semanticScopeMap);

      let semanticStyle = middle.style;
      semanticScopes.forEach((scope) => {
        semanticStyle = resolveStyleFromScope(scope, ruleIndex, semanticStyle);
      });

      const bestSemanticRule = getBestSemanticRule(semanticRuleIndex, semantic, documentLanguage);
      if (bestSemanticRule) {
        semanticStyle = mergeStyle(semanticStyle, bestSemanticRule.style);
      }

      middle.semantic = {
        type: semantic.tokenType,
        modifiers: semantic.modifiers,
        scopes: semanticScopes
      };
      middle.style = semanticStyle;
      next.push(middle);

      if (midEnd < token.endIndex) {
        next.push(cloneTokenSegment(token, midEnd, token.endIndex));
      }
    }
    working = next;
  }

  return working;
}

function normalizeSemanticTokenEntries(entries, documentLanguage) {
  return (Array.isArray(entries) ? entries : []).map((entry) => {
    const modifiers = Array.isArray(entry.modifiers) ? entry.modifiers : [];
    return {
      line: entry.line,
      startChar: entry.startChar,
      endChar: entry.startChar + entry.length,
      length: entry.length,
      tokenType: entry.tokenType,
      modifiers,
      modifierSet: new Set(modifiers),
      language: documentLanguage
    };
  });
}

function fetchSemanticTokensFromCompiler(inputPath) {
  const repoRoot = path.resolve(__dirname, '..', '..', '..');
  const result = spawnSync('ruby', ['bin/mtc', 'semantic-tokens', inputPath], {
    cwd: repoRoot,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || `mtc semantic-tokens failed with status ${result.status}`).trim());
  }

  return JSON.parse(result.stdout);
}

function escapeHtml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function tokenStyleToCss(style) {
  const css = [];
  if (style.foreground) {
    css.push(`color:${style.foreground}`);
  }
  if (style.background) {
    css.push(`background:${style.background}`);
  }
  if (style.fontStyle.italic) {
    css.push('font-style:italic');
  }
  if (style.fontStyle.bold) {
    css.push('font-weight:700');
  }
  const decorations = [];
  if (style.fontStyle.underline) {
    decorations.push('underline');
  }
  if (style.fontStyle.strikethrough) {
    decorations.push('line-through');
  }
  if (decorations.length > 0) {
    css.push(`text-decoration:${decorations.join(' ')}`);
  }
  return css.join(';');
}

function buildHtml(snapshot) {
  const pageBg = snapshot.theme.colors['editor.background'] || '#1e1e1e';
  const pageFg = snapshot.theme.colors['editor.foreground'] || '#d4d4d4';
  const rows = [];

  for (const line of snapshot.lines) {
    const spans = line.tokens
      .map((token) => {
        const text = token.text.length === 0 ? ' ' : token.text;
        return `<span style="${tokenStyleToCss(token.style)}">${escapeHtml(text)}</span>`;
      })
      .join('');
    rows.push(`<div class="line"><span class="ln">${line.lineNumber}</span>${spans}</div>`);
  }

  return [
    '<!doctype html>',
    '<html lang="en">',
    '<head>',
    '  <meta charset="utf-8">',
    '  <meta name="viewport" content="width=device-width, initial-scale=1">',
    '  <title>Milk Tea TextMate Snapshot</title>',
    '  <style>',
    `    body { margin: 0; background: ${pageBg}; color: ${pageFg}; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }`,
    '    .wrap { padding: 20px; }',
    '    .meta { margin-bottom: 16px; opacity: 0.8; }',
    '    .line { white-space: pre; line-height: 1.5; }',
    '    .ln { display: inline-block; width: 56px; text-align: right; margin-right: 16px; opacity: 0.45; user-select: none; }',
    '  </style>',
    '</head>',
    '<body>',
    '  <div class="wrap">',
    `    <div class="meta">Theme: ${escapeHtml(snapshot.theme.name)} | Grammar: ${escapeHtml(snapshot.grammar.scopeName)} | Source: ${escapeHtml(snapshot.inputFile)}</div>`,
    `    ${rows.join('\n')}`,
    '  </div>',
    '</body>',
    '</html>'
  ].join('\n');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    process.exit(0);
  }

  if (!args.inputPath) {
    usage();
    throw new Error('Missing required argument: --input');
  }

  const inputPath = ensureAbs(args.inputPath);
  const grammarPath = ensureAbs(args.grammarPath);
  const jsonOut = ensureAbs(args.jsonOut || `${inputPath}.snapshot.json`);
  const htmlOut = ensureAbs(args.htmlOut || `${inputPath}.snapshot.html`);

  if (!fs.existsSync(inputPath)) {
    throw new Error(`Input file not found: ${inputPath}`);
  }
  if (!fs.existsSync(grammarPath)) {
    throw new Error(`Grammar file not found: ${grammarPath}`);
  }

  let themeInfo;
  if (args.themeFile) {
    const themePath = ensureAbs(args.themeFile);
    if (!fs.existsSync(themePath)) {
      throw new Error(`Theme file not found: ${themePath}`);
    }
    themeInfo = {
      path: themePath,
      id: null,
      label: path.basename(themePath),
      uiTheme: null,
      extensionPath: null
    };
  } else {
    themeInfo = findThemeByName(args.themeName);
    if (!themeInfo) {
      throw new Error(`Theme not found by name/id: ${args.themeName}`);
    }
  }

  const resolvedTheme = resolveThemeFileWithIncludes(themeInfo.path);
  const builtinSemanticScopeMap = loadBuiltinSemanticScopeMap();
  const settingsSemantic = loadMergedSemanticSettingRules(inputPath, themeInfo, resolvedTheme, args.themeName);
  const rawTheme = toRawTextMateTheme(resolvedTheme);
  const themeSemanticRules = Array.isArray(resolvedTheme.semanticTokenColorRules)
    ? resolvedTheme.semanticTokenColorRules
    : [];
  const semanticRuleIndex = mergeSemanticRuleSets(themeSemanticRules, settingsSemantic.rules);
  const tokenColorRuleIndex = buildTokenColorRuleIndex(rawTheme);
  const grammarRaw = fs.readFileSync(grammarPath, 'utf8');
  const grammarJson = loadJson(grammarPath);
  const extensionRoot = path.resolve(__dirname, '..');
  const extensionPackagePath = path.join(extensionRoot, 'package.json');
  const contributedGrammars = new Map();
  if (fs.existsSync(extensionPackagePath)) {
    const extensionPackage = loadJson(extensionPackagePath);
    for (const entry of extensionPackage.contributes?.grammars || []) {
      if (!entry.scopeName || !entry.path) {
        continue;
      }
      contributedGrammars.set(entry.scopeName, {
        path: path.resolve(extensionRoot, entry.path),
        raw: null,
      });
    }
  }
  contributedGrammars.set(grammarJson.scopeName, { path: grammarPath, raw: grammarRaw });
  const source = fs.readFileSync(inputPath, 'utf8');
  const lines = source.split(/\r?\n/);

  await loadOniguruma();

  const onigLib = Promise.resolve({
    createOnigScanner(patterns) {
      return new oniguruma.OnigScanner(patterns);
    },
    createOnigString(s) {
      return new oniguruma.OnigString(s);
    }
  });

  const registry = new Registry({
    onigLib,
    theme: rawTheme,
    loadGrammar: async (scopeName) => {
      const entry = contributedGrammars.get(scopeName);
      if (!entry) {
        return null;
      }

      if (entry.raw == null) {
        entry.raw = fs.readFileSync(entry.path, 'utf8');
      }
      return parseRawGrammar(entry.raw, entry.path);
    }
  });

  const grammar = await registry.loadGrammar(grammarJson.scopeName);
  if (!grammar) {
    throw new Error(`Failed to load grammar for scope: ${grammarJson.scopeName}`);
  }

  const colorMap = registry.getColorMap();
  let ruleStack = INITIAL;
  const snapshotLines = [];

  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const lineText = lines[lineIndex];
    const r1 = grammar.tokenizeLine(lineText, ruleStack);
    const r2 = grammar.tokenizeLine2(lineText, ruleStack);
    ruleStack = r1.ruleStack;

    const tokens = [];
    const packed = r2.tokens;
    for (let i = 0; i < packed.length; i += 2) {
      const startIndex = packed[i];
      const metadata = packed[i + 1];
      const endIndex = i + 2 < packed.length ? packed[i + 2] : lineText.length;
      const overlapping = r1.tokens.filter(
        (token) => token.startIndex < endIndex && token.endIndex > startIndex
      );
      const scopesToken = overlapping.length > 0 ? overlapping[overlapping.length - 1] : null;
      const text = lineText.slice(startIndex, endIndex);
      tokens.push({
        startIndex,
        endIndex,
        text,
        scopes: scopesToken ? scopesToken.scopes : [],
        style: decodeMetadata(metadata, colorMap)
      });
    }

    snapshotLines.push({
      lineNumber: lineIndex + 1,
      text: lineText,
      tokens
    });
  }

  let semanticOverlay = null;
  if (args.semanticOverlay && args.semanticOverlay !== 'none') {
    if (args.semanticOverlay !== 'compiler') {
      throw new Error(`Unsupported --semantic-overlay mode: ${args.semanticOverlay}`);
    }

    const semanticPayload = fetchSemanticTokensFromCompiler(inputPath);
    if (semanticPayload && semanticPayload.legend) {
      const entries = semanticPayload.entries
        ? normalizeSemanticTokenEntries(semanticPayload.entries, 'milk-tea')
        : decodeSemanticTokensData(semanticPayload.data, semanticPayload.legend, 'milk-tea');
      const lineGroups = new Map();
      entries.forEach((entry) => {
        const list = lineGroups.get(entry.line) || [];
        list.push(entry);
        lineGroups.set(entry.line, list);
      });

      snapshotLines.forEach((line) => {
        const overlays = lineGroups.get(line.lineNumber - 1) || [];
        if (overlays.length === 0) {
          return;
        }
        line.tokens = overlaySemanticOnLineTokens(
          line.tokens,
          overlays,
          tokenColorRuleIndex,
          semanticRuleIndex,
          'milk-tea',
          builtinSemanticScopeMap.entries
        );
      });

      semanticOverlay = {
        mode: 'compiler',
        legend: semanticPayload.legend,
        tokenCount: entries.length,
        settingsRulesApplied: settingsSemantic.rules.length,
        settingsSources: settingsSemantic.sources,
        settingsEnabled: settingsSemantic.enabled,
        semanticScopeMapSource: builtinSemanticScopeMap.source,
        semanticScopeMapEntries: builtinSemanticScopeMap.entries.length
      };
    } else {
      semanticOverlay = {
        mode: 'compiler',
        legend: null,
        tokenCount: 0,
        settingsRulesApplied: settingsSemantic.rules.length,
        settingsSources: settingsSemantic.sources,
        settingsEnabled: settingsSemantic.enabled,
        semanticScopeMapSource: builtinSemanticScopeMap.source,
        semanticScopeMapEntries: builtinSemanticScopeMap.entries.length,
        warning: 'Compiler semantic token payload not available; overlay skipped.'
      };
    }
  }

  const snapshot = {
    generatedAt: new Date().toISOString(),
    inputFile: inputPath,
    grammar: {
      path: grammarPath,
      scopeName: grammarJson.scopeName,
      fileTypes: grammarJson.fileTypes || []
    },
    theme: {
      name: themeInfo.label || themeInfo.id || resolvedTheme.name || args.themeName,
      id: themeInfo.id,
      uiTheme: themeInfo.uiTheme,
      path: themeInfo.path,
      colors: {
        'editor.background': (resolvedTheme.colors && resolvedTheme.colors['editor.background']) || null,
        'editor.foreground': (resolvedTheme.colors && resolvedTheme.colors['editor.foreground']) || null
      }
    },
    colorMap,
    semanticRules: {
      themeRuleCount: themeSemanticRules.length,
      settingsRuleCount: settingsSemantic.rules.length,
      mergedRuleCount: semanticRuleIndex.length,
      settingsSources: settingsSemantic.sources,
      settingsEnabled: settingsSemantic.enabled,
      scopeMapSource: builtinSemanticScopeMap.source,
      scopeMapEntries: builtinSemanticScopeMap.entries.length
    },
    semanticOverlay,
    lines: snapshotLines
  };

  fs.mkdirSync(path.dirname(jsonOut), { recursive: true });
  fs.writeFileSync(jsonOut, JSON.stringify(snapshot, null, 2));

  fs.mkdirSync(path.dirname(htmlOut), { recursive: true });
  fs.writeFileSync(htmlOut, buildHtml(snapshot));

  console.log(`Theme resolved: ${themeInfo.path}`);
  console.log(`JSON snapshot: ${jsonOut}`);
  console.log(`HTML snapshot: ${htmlOut}`);
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
