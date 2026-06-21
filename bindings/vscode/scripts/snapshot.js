#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const vsctm = require("vscode-textmate");
const onig = require("vscode-oniguruma");

const SYNTAXES_DIR = path.join(__dirname, "..", "syntaxes");
const THEMES_DIR = path.join(__dirname, "..", "themes");

const GRAMMAR_MAP = {
  "source.milk-tea": "milk-tea.tmLanguage.json",
  "source.glsl": "glsl.tmLanguage.json",
  "source.json": "json.tmLanguage.json",
  "source.jsonc": "jsonc.tmLanguage.json",
  "source.sql": "sql.tmLanguage.json",
};

const SCOPE_MAP = {
  keyword:      "keyword.control.milk-tea",
  variable:     "variable.other.milk-tea",
  parameter:    "variable.other.milk-tea",
  property:     "variable.other.milk-tea",
  function:     "entity.name.function.milk-tea",
  method:       "support.function.milk-tea",
  type:         "entity.name.type.milk-tea",
  namespace:    "entity.name.type.milk-tea",
  number:       "constant.numeric.milk-tea",
  string:       "string.quoted.milk-tea",
  operator:     "keyword.operator.arithmetic.milk-tea",
  enumMember:   "constant.other.enum.milk-tea",
  macro:        "entity.name.annotation.milk-tea",
  decorator:    "entity.name.annotation.milk-tea",
  comment:      "comment.line.milk-tea",
};

const MODIFIER_STYLES = {
  declaration: { boldOverride: true },
  static: { italicOverride: true },
  deprecated: { strikethrough: true },
  abstract: { italicOverride: true },
  async: { italicOverride: true },
};

function parseArgs() {
  const args = { input: null, theme: null, output: null, semantic: null, showHelp: false };
  const argv = process.argv.slice(2);
  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    if (arg === "--theme" || arg === "-t") {
      args.theme = argv[++i];
    } else if (arg === "--output" || arg === "-o") {
      args.output = argv[++i];
    } else if (arg === "--semantic" || arg === "-s") {
      args.semantic = argv[++i];
    } else if (arg === "--help" || arg === "-h") {
      args.showHelp = true;
    } else if (!arg.startsWith("-")) {
      args.input = arg;
    }
    i++;
  }
  return args;
}

function printUsage() {
  process.stderr.write(
    "Usage: node snapshot.js <input.mt> [--theme theme.json] [-o output.html] [--semantic semantic.json]\n\n" +
      "  Generate an HTML snapshot of a Milk Tea source file with VS Code syntax\n" +
      "  highlighting using the active TextMate grammar and theme.\n\n" +
      "  Options:\n" +
      "    --theme, -t     Path to a VS Code theme JSON file (default: 2026 Dark).\n" +
      "    --output, -o    Write HTML to this file instead of stdout.\n" +
      "    --semantic, -s  Path to semantic token JSON file for overlay highlighting.\n" +
      "    --help, -h      Show this message.\n",
  );
}

function resolveTheme(themePath) {
  const theme = JSON.parse(fs.readFileSync(themePath, "utf8"));
  if (!theme.include) return theme;

  const includePath = path.resolve(path.dirname(themePath), theme.include);
  const parent = resolveTheme(includePath);

  const merged = { name: theme.name || parent.name };
  if (parent.colors || theme.colors) {
    merged.colors = Object.assign({}, parent.colors || {}, theme.colors || {});
  }
  if (parent.tokenColors || theme.tokenColors) {
    merged.tokenColors = [].concat(parent.tokenColors || [], theme.tokenColors || []);
  }
  if (parent.semanticTokenColors || theme.semanticTokenColors) {
    merged.semanticTokenColors = Object.assign({}, parent.semanticTokenColors || {}, theme.semanticTokenColors || {});
  }
  return merged;
}

function buildColorResolver(theme) {
  const rules = [];
  let idx = 0;
  for (const entry of theme.tokenColors || []) {
    const scopes = typeof entry.scope === "string" ? [entry.scope] : Array.isArray(entry.scope) ? entry.scope : [];
    const settings = entry.settings || {};
    if (!settings.foreground && !settings.fontStyle) continue;
    for (const scope of scopes) {
      rules.push({
        scope: scope,
        foreground: settings.foreground || null,
        fontStyle: settings.fontStyle || null,
        specificity: scope.split(".").length,
        index: idx++,
      });
    }
  }
  rules.sort((a, b) => b.specificity - a.specificity || b.index - a.index);

  return function resolveToken(scopes) {
    for (let i = scopes.length - 1; i >= 0; i--) {
      const ts = scopes[i];
      for (const rule of rules) {
        if (ts === rule.scope || ts.startsWith(rule.scope + ".")) {
          return rule;
        }
      }
    }
    return null;
  };
}

function buildSemanticOverlay(entries, theme) {
  if (!entries || entries.length === 0) return null;
  const themeSemColors = (theme && theme.semanticTokenColors) || {};
  const resolveTextMate = buildColorResolver(theme);
  const overlay = [];
  for (const entry of entries) {
    const lineNum = entry.line;
    if (!overlay[lineNum]) overlay[lineNum] = {};
    const fg = themeSemColors[entry.tokenType] || deriveSemanticColor(entry, resolveTextMate);
    if (!fg) continue;
    const result = { foreground: fg };
    for (const mod of entry.modifiers || []) {
      const style = MODIFIER_STYLES[mod];
      if (!style) continue;
      if (style.boldOverride) result.boldOverride = true;
      if (style.italicOverride) result.italicOverride = true;
      if (style.strikethrough) result.strikethrough = true;
    }
    for (let c = entry.startChar; c < entry.startChar + entry.length; c++) {
      overlay[lineNum][c] = result;
    }
  }
  return overlay;
}

function deriveSemanticColor(entry, resolveTextMate) {
  let scope = SCOPE_MAP[entry.tokenType];
  if (!scope) return null;
  const mods = entry.modifiers || [];
  if (entry.tokenType === "variable" && mods.includes("readonly")) {
    scope = "variable.other.constant.milk-tea";
  }
  const tm = resolveTextMate([scope]);
  return tm ? tm.foreground : null;
}

function escapeHtml(str) {
  return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

async function registryFactory(onigLib) {
  return new vsctm.Registry({
    onigLib: Promise.resolve(onigLib),
    async loadGrammar(scopeName) {
      const filename = GRAMMAR_MAP[scopeName];
      if (!filename) return null;
      const filePath = path.join(SYNTAXES_DIR, filename);
      if (!fs.existsSync(filePath)) return null;
      const raw = fs.readFileSync(filePath, "utf8");
      return vsctm.parseRawGrammar(raw, filePath);
    },
  });
}

function dominantSemanticColor(semanticLine, start, end) {
  if (!semanticLine) return null;
  let first = null;
  for (let c = start; c < end; c++) {
    const s = semanticLine[c];
    if (!s) continue;
    if (!first) first = s;
    else if (s.foreground !== first.foreground) return null;
  }
  return first;
}

class StyleRegistry {
  constructor(semanticEntries, theme, resolveTextMate) {
    this.map = new Map();
    this.styles = [];
    this.labels = new Map();
    this.classNames = new Set();
    this._buildLabelMap(semanticEntries, theme, resolveTextMate);
  }

  _buildLabelMap(semanticEntries, theme, resolveTextMate) {
    const themeSemColors = (theme && theme.semanticTokenColors) || {};
    for (const entry of semanticEntries || []) {
      let fg = themeSemColors[entry.tokenType];
      if (!fg && resolveTextMate) {
        let scope = SCOPE_MAP[entry.tokenType];
        if (scope && entry.tokenType === "variable" && (entry.modifiers || []).includes("readonly")) {
          scope = "variable.other.constant.milk-tea";
        }
        if (scope) {
          const tm = resolveTextMate([scope]);
          if (tm) fg = tm.foreground;
        }
      }
      if (!fg) continue;
      const mods = entry.modifiers || [];
      const bold = mods.includes("declaration");
      const key = this._styleKey(fg, bold, false, false);
      if (this.labels.has(key)) continue;
      this.labels.set(key, bold ? `${entry.tokenType}-decl` : entry.tokenType);
    }
  }

  _styleKey(foreground, bold, italic, strikethrough) {
    return [foreground || "", bold ? "1" : "0", italic ? "1" : "0", strikethrough ? "1" : "0"].join("|");
  }

  _scopeLabel(scopes) {
    if (!scopes) return null;
    const scope = scopes.find(s => s !== "source.milk-tea");
    if (!scope) return null;
    const parts = scope.replace(/\.milk-tea$/, "").split(".");
    if (parts[0] === "comment") return "comment";
    if (parts[0] === "string") return "string";
    if (parts[0] === "constant") return parts[1] === "numeric" ? "number" : parts.slice(0, 2).join("-");
    if (parts[0] === "keyword" || parts[0] === "storage") return parts.slice(0, 2).join("-");
    if (parts[0] === "variable" || parts[0] === "support") return parts.slice(0, 2).join("-");
    return parts.slice(0, 2).join("-");
  }

  _cssSafe(label) {
    return label.replace(/[^a-zA-Z0-9_-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
  }

  _uniqueClass(candidate) {
    let name = candidate;
    if (this.classNames.has(name)) {
      let seq = 2;
      while (this.classNames.has(`${candidate}-${seq}`)) seq++;
      name = `${candidate}-${seq}`;
    }
    this.classNames.add(name);
    return name;
  }

  register(foreground, bold, italic, strikethrough, tmScopes) {
    const k = this._styleKey(foreground, bold, italic, strikethrough);
    let cls = this.map.get(k);
    if (cls) return cls;

    let label = this.labels.get(k);
    if (!label && tmScopes) {
      label = this._scopeLabel(tmScopes);
    }
    if (!label) {
      label = foreground ? foreground.replace("#", "") : "none";
    }

    let candidate = this._cssSafe(label);
    let clsBase = `tk-${candidate}`;
    if (this.classNames.has(clsBase)) {
      clsBase = `tk-${candidate}-${foreground.replace("#", "")}`;
    }
    cls = this._uniqueClass(clsBase);
    this.map.set(k, cls);

    const rules = [];
    if (foreground) rules.push(`color:${foreground}`);
    if (bold) rules.push("font-weight:bold");
    if (italic) rules.push("font-style:italic");
    if (strikethrough) rules.push("text-decoration:line-through");
    this.styles.push(`.${cls} { ${rules.join("; ")} }`);
    return cls;
  }

  getCSS() {
    return this.styles.join("\n");
  }
}

function buildLineHtml(line, tokens, resolveTextMate, semanticLine, styles) {
  let html = "";
  for (const token of tokens) {
    const text = escapeHtml(line.substring(token.startIndex, token.endIndex));
    let foreground = null;
    let bold = false;
    let italic = false;
    let strikethrough = false;
    let fromSemantic = false;

    const sem = dominantSemanticColor(semanticLine, token.startIndex, token.endIndex);
    if (sem) {
      foreground = sem.foreground;
      bold = sem.boldOverride || false;
      italic = sem.italicOverride || false;
      strikethrough = sem.strikethrough || false;
      fromSemantic = true;
    }

    let tmRule = null;
    if (!foreground) {
      tmRule = resolveTextMate(token.scopes);
      if (tmRule && tmRule.foreground) {
        foreground = tmRule.foreground;
        if (tmRule.fontStyle) {
          for (const s of tmRule.fontStyle.split(/\s+/)) {
            if (s === "bold") bold = bold || true;
            if (s === "italic") italic = italic || true;
          }
        }
      }
    }

    if (foreground) {
      const tmScopes = fromSemantic ? null : token.scopes;
      const cls = styles.register(foreground, bold, italic, strikethrough, tmScopes);
      html += `<span class="${cls}">${text}</span>`;
    } else {
      html += text;
    }
  }
  return html;
}

async function main() {
  const args = parseArgs();
  if (args.showHelp || !args.input) {
    printUsage();
    process.exit(args.showHelp ? 0 : 1);
  }

  if (!fs.existsSync(args.input)) {
    process.stderr.write(`snapshot: input file not found: ${args.input}\n`);
    process.exit(1);
  }

  const themePath = args.theme || path.join(THEMES_DIR, "2026-dark.json");
  if (!fs.existsSync(themePath)) {
    process.stderr.write(`snapshot: theme file not found: ${themePath}\n`);
    process.exit(1);
  }

  let semanticEntries = [];
  let hadSemantic = false;
  if (args.semantic) {
    if (fs.existsSync(args.semantic)) {
      try {
        semanticEntries = JSON.parse(fs.readFileSync(args.semantic, "utf8"));
      } catch (e) {
        process.stderr.write(`snapshot: failed to parse semantic token file: ${e.message}\n`);
      }
    }
  }

  const theme = resolveTheme(themePath);
  const resolveTextMate = buildColorResolver(theme);
  const colors = theme.colors || {};
  const bgColor = colors["editor.background"] || "#121314";
  const fgColor = colors["editor.foreground"] || "#BBBEBF";

  const semanticOverlay = buildSemanticOverlay(semanticEntries, theme);
  if (semanticOverlay) hadSemantic = true;

  const wasmBin = fs.readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm"));
  await onig.loadWASM(wasmBin);
  const onigLib = { createOnigScanner: onig.createOnigScanner, createOnigString: onig.createOnigString };

  const registry = await registryFactory(onigLib);
  const grammar = await registry.loadGrammar("source.milk-tea");
  if (!grammar) {
    process.stderr.write("snapshot: failed to load milk-tea grammar\n");
    process.exit(1);
  }

  const source = fs.readFileSync(args.input, "utf8");
  const lines = source.split("\n");
  const styles = new StyleRegistry(semanticEntries, theme, resolveTextMate);

  let ruleStack = null;
  const htmlLines = [];
  const digitCount = String(lines.length).length;

  for (let lineIdx = 0; lineIdx < lines.length; lineIdx++) {
    const line = lines[lineIdx];
    const result = grammar.tokenizeLine(line, ruleStack);
    ruleStack = result.ruleStack;
    const semanticLine = semanticOverlay ? semanticOverlay[lineIdx] : null;
    const lineHtml = buildLineHtml(line, result.tokens, resolveTextMate, semanticLine, styles);
    const num = String(lineIdx + 1).padStart(digitCount);
    htmlLines.push(`<span class="line" id="L${lineIdx + 1}"><span class="ln">${num}</span>${lineHtml}</span>`);
  }

  let titleExtra = "";
  if (args.semantic && !hadSemantic) {
    titleExtra = " (semantic unused)";
  } else if (hadSemantic) {
    titleExtra = " (semantic)";
  }

  const padW = digitCount + 2;

  const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>${escapeHtml(path.basename(args.input))} &mdash; Milk Tea Snapshot${titleExtra}</title>
<style>
body {
  background-color: ${bgColor};
  color: ${fgColor};
  font-family: ui-monospace, SFMono-Regular, 'Cascadia Code', Consolas, monospace;
  font-size: 14px;
  line-height: 1.5;
  margin: 0;
  padding: 16px;
}
.line {
  display: block;
  white-space: pre;
}
.ln {
  display: inline-block;
  width: ${padW}ch;
  margin-right: 1ch;
  text-align: right;
  color: ${colors["editorLineNumber.foreground"] || "#6e7681"};
  user-select: none;
}
${styles.getCSS()}
</style>
</head>
<body>
${htmlLines.join("\n")}
</body>
</html>
`;

  if (args.output) {
    fs.writeFileSync(args.output, html, "utf8");
    process.stderr.write(`Snapshot written to ${args.output}\n`);
  } else {
    process.stdout.write(html);
  }
}

main().catch((err) => {
  process.stderr.write(`snapshot: ${err.message}\n`);
  process.exit(1);
});
