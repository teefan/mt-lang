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

// ---- Theme resolution (copied from snapshot.js) ----

function resolveTheme(themePath) {
  const theme = JSON.parse(fs.readFileSync(themePath, "utf8"));
  if (!theme.include) return theme;
  const includePath = path.resolve(path.dirname(themePath), theme.include);
  const parent = resolveTheme(includePath);
  const merged = { name: theme.name || parent.name };
  if (parent.colors || theme.colors)
    merged.colors = Object.assign({}, parent.colors || {}, theme.colors || {});
  if (parent.tokenColors || theme.tokenColors)
    merged.tokenColors = [].concat(parent.tokenColors || [], theme.tokenColors || []);
  if (parent.semanticTokenColors || theme.semanticTokenColors)
    merged.semanticTokenColors = Object.assign(
      {}, parent.semanticTokenColors || {}, theme.semanticTokenColors || {});
  return merged;
}

// ---- Snapshot.js color resolver (current algorithm) ----

// Copied verbatim from snapshot.js — must stay in sync
function buildSnapshotResolver(theme) {
  const rules = [];
  let idx = 0;
  for (const entry of theme.tokenColors || []) {
    const scopes = typeof entry.scope === "string"
      ? [entry.scope]
      : Array.isArray(entry.scope) ? entry.scope : [];
    const settings = entry.settings || {};
    if (!settings.foreground && !settings.fontStyle) continue;
    for (const scope of scopes) {
      rules.push({
        scope,
        foreground: settings.foreground || null,
        fontStyle: settings.fontStyle || null,
        specificity: scope.split(".").length,
        index: idx++,
      });
    }
  }

  return function resolveToken(scopes) {
    let bestRule = null;
    let bestSpec = -1;
    let bestScopeIdx = -1;
    for (const rule of rules) {
      for (let i = 0; i < scopes.length; i++) {
        const ts = scopes[i];
        if (ts === rule.scope || ts.startsWith(rule.scope + ".")) {
          if (
            rule.specificity > bestSpec ||
            (rule.specificity === bestSpec && i > bestScopeIdx) ||
            (rule.specificity === bestSpec && i === bestScopeIdx && (bestRule === null || rule.index > bestRule.index))
          ) {
            bestRule = rule;
            bestSpec = rule.specificity;
            bestScopeIdx = i;
          }
          break;
        }
      }
    }
    return bestRule;
  };
}

// ---- TextMate-compliant color resolver (reference algorithm) ----

function buildTextMateResolver(theme) {
  const rules = [];
  let idx = 0;
  for (const entry of theme.tokenColors || []) {
    const scopes = typeof entry.scope === "string"
      ? [entry.scope]
      : Array.isArray(entry.scope) ? entry.scope : [];
    const settings = entry.settings || {};
    if (!settings.foreground && !settings.fontStyle) continue;
    for (const scope of scopes) {
      rules.push({ scope, foreground: settings.foreground || null, fontStyle: settings.fontStyle || null, index: idx++ });
    }
  }

  return function resolveToken(tokenScopes) {
    // TextMate matching algorithm:
    // For each rule, compute the maximum match rank across all token scopes.
    // The rule with the highest rank wins. Tie-breaking by rule index (last wins).
    let bestRule = null;
    let bestRank = -1;
    for (const rule of rules) {
      let rank = rankMatch(tokenScopes, rule.scope);
      if (rank >= 0 && (rank > bestRank || (rank === bestRank && rule.index > (bestRule ? bestRule.index : -1)))) {
        bestRule = rule;
        bestRank = rank;
      }
    }
    return bestRule;
  };
}

// TextMate rank: (scope_element_count << 16) + parent_depth_weight
// A rule matches if its scope is a prefix segment of any token scope.
// Higher specificity = higher rank.
function rankMatch(tokenScopes, ruleScope) {
  let bestRank = -1;
  const ruleParts = ruleScope.split(".");
  for (let i = 0; i < tokenScopes.length; i++) {
    const tokenParts = tokenScopes[i].split(".");
    // Check if ruleScope matches this token scope as a prefix
    if (tokenParts.length >= ruleParts.length) {
      let match = true;
      for (let j = 0; j < ruleParts.length; j++) {
        if (tokenParts[j] !== ruleParts[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        // rank = scope specificity * fixed weight + parent match bonus
        // Deeper token scopes that match get higher rank
        const rank = (ruleParts.length << 12) + i;
        if (rank > bestRank) bestRank = rank;
      }
    }
  }
  return bestRank;
}

// ---- vscode-textmate registry ----

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

// ---- Helpers ----

function colorToHex(color) {
  if (!color) return "none";
  const c = color.toUpperCase();
  if (c.length === 4) return "#" + c[1] + c[1] + c[2] + c[2] + c[3] + c[3];
  return c;
}

function styleToStr(fontStyle) {
  const parts = [];
  if (fontStyle) {
    for (const s of fontStyle.split(/\s+/)) parts.push(s);
  }
  return parts.join(",") || "normal";
}

// ---- Main comparison ----

async function main() {
  const args = process.argv.slice(2);
  const inputFile = args[0] || path.join(__dirname, "..", "..", "..", "examples", "language_baseline.mt");
  const themePath = args[1] || path.join(THEMES_DIR, "2026-dark.json");
  const outputDiff = args.includes("--diff");

  if (!fs.existsSync(inputFile)) {
    process.stderr.write(`Input file not found: ${inputFile}\n`);
    process.exit(1);
  }

  const theme = resolveTheme(themePath);
  const snapshotResolver = buildSnapshotResolver(theme);
  const textmateResolver = buildTextMateResolver(theme);

  // Tokenize
  const wasmBin = fs.readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm"));
  await onig.loadWASM(wasmBin);
  const onigLib = { createOnigScanner: onig.createOnigScanner, createOnigString: onig.createOnigString };
  const registry = await registryFactory(onigLib);
  const grammar = await registry.loadGrammar("source.milk-tea");
  if (!grammar) { process.stderr.write("Failed to load grammar\n"); process.exit(1); }

  const source = fs.readFileSync(inputFile, "utf8");
  const lines = source.split("\n");

  let totalTokens = 0;
  let differingTokens = 0;
  let differingForeground = 0;
  let differingFontStyle = 0;
  const diffs = [];

  let ruleStack = null;
  for (let lineIdx = 0; lineIdx < lines.length; lineIdx++) {
    const line = lines[lineIdx];
    const result = grammar.tokenizeLine(line, ruleStack);
    ruleStack = result.ruleStack;

    for (const token of result.tokens) {
      if (token.startIndex === token.endIndex) continue;
      totalTokens++;

      const snap = snapshotResolver(token.scopes);
      const tmate = textmateResolver(token.scopes);

      const snapFg = snap ? snap.foreground : null;
      const tmateFg = tmate ? tmate.foreground : null;
      const snapStyle = snap ? snap.fontStyle : null;
      const tmateStyle = tmate ? tmate.fontStyle : null;

      const fgDiff = snapFg !== tmateFg;
      const styleDiff = snapStyle !== tmateStyle;

      if (fgDiff || styleDiff) {
        differingTokens++;
        if (fgDiff) differingForeground++;
        if (styleDiff) differingFontStyle++;

        const text = line.substring(token.startIndex, token.endIndex);
        diffs.push({
          line: lineIdx + 1,
          col: token.startIndex + 1,
          text: text.length > 40 ? text.substring(0, 37) + "..." : text,
          scopes: token.scopes.join(" → "),
          snapshot: fgDiff ? colorToHex(snapFg) : "same",
          textmate: fgDiff ? colorToHex(tmateFg) : "same",
          snapStyle: styleDiff ? styleToStr(snapStyle) : "same",
          tmateStyle: styleDiff ? styleToStr(tmateStyle) : "same",
        });
      }
    }
  }

  // Print summary
  console.log(`File: ${path.basename(inputFile)}`);
  console.log(`Theme: ${path.basename(themePath)} (resolved: ${theme.name})`);
  console.log(`Total tokens: ${totalTokens}`);
  console.log(`Tokens with color mismatches: ${differingTokens} (${(differingTokens / totalTokens * 100).toFixed(1)}%)`);
  console.log(`  Foreground mismatches: ${differingForeground}`);
  console.log(`  Font style mismatches: ${differingFontStyle}`);
  console.log("");

  if (diffs.length > 0) {
    console.log("Mismatch details:");
    console.log("  Snapshot = snapshot.js current color | TextMate = reference algorithm");
    console.log("");

    const showCount = Math.min(diffs.length, 50);
    for (let i = 0; i < showCount; i++) {
      const d = diffs[i];
      console.log(`  L${String(d.line).padStart(4)}:${String(d.col).padStart(3)}  "${d.text}"`);
      console.log(`          scopes: ${d.scopes}`);
      console.log(`          snapshot: fg=${d.snapshot} style=${d.snapStyle}`);
      console.log(`          textmate: fg=${d.textmate} style=${d.tmateStyle}`);
      console.log("");
    }
    if (diffs.length > showCount) {
      console.log(`  ... and ${diffs.length - showCount} more mismatches`);
    }
  } else {
    console.log("All tokens match. snapshot.js color resolution is correct.");
  }

  process.exit(differingTokens > 0 ? 1 : 0);
}

main().catch((err) => {
  process.stderr.write(`Error: ${err.message}\n${err.stack}\n`);
  process.exit(2);
});
