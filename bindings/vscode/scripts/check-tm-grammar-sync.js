#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

const VSCODE_ROOT = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(VSCODE_ROOT, '..', '..');

const GRAMMAR_PATH = path.join(VSCODE_ROOT, 'syntaxes', 'milk-tea.tmLanguage.json');
const TOKEN_PATH = path.join(REPO_ROOT, 'lib', 'milk_tea', 'core', 'token.rb');
const TYPES_PATH = path.join(REPO_ROOT, 'lib', 'milk_tea', 'core', 'types.rb');
const LSP_PATH = path.join(REPO_ROOT, 'lib', 'milk_tea', 'lsp', 'server.rb');

const EXPECTED_SCHEMA_URL = 'https://json.schemastore.org/tmlanguage.json';

const CONTROL_KEYWORD_WORDS = ['if', 'else', 'for', 'in', 'while', 'break', 'continue', 'pass', 'return', 'match', 'defer', 'unsafe', 'await', 'when'];
const CONTEXTUAL_KEYWORDS = new Set(['when']);
const OPERATOR_KEYWORD_WORDS = ['and', 'or', 'not', 'as', 'in', 'implements', 'size_of', 'align_of', 'offset_of', 'consuming', 'inout', 'out'];
const MODIFIER_KEYWORD_WORDS = ['public', 'async', 'editable'];
const CONSTANT_LANGUAGE_WORDS = ['true', 'false', 'null'];
const SPECIAL_LANGUAGE_WORDS = ['this'];
const TEXTMATE_BUILTIN_EXCLUSIONS = new Set(['array', 'span']);

function readText(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function extractRubyHashKeys(source, constantName) {
  const match = source.match(new RegExp(`${constantName}\\s*=\\s*\\{([\\s\\S]*?)\\}\\.freeze`, 'm'));
  if (!match) {
    throw new Error(`could not find Ruby hash constant ${constantName}`);
  }

  return Array.from(match[1].matchAll(/"([^"]+)"\s*=>/g), (entry) => entry[1]);
}

function extractRubyPercentW(source, constantName) {
  const match = source.match(new RegExp(`${constantName}\\s*=\\s*%w\\[([\\s\\S]*?)\\]`, 'm'));
  if (!match) {
    throw new Error(`could not find Ruby %w constant ${constantName}`);
  }

  return match[1].trim().split(/\s+/).filter(Boolean);
}

function extractWordPatternWords(patternSource, label) {
  const alternation = patternSource.match(/^\\b\(([^)]+)\)\\b$/);
  if (alternation) {
    return alternation[1].split('|');
  }

  const single = patternSource.match(/^\\b([A-Za-z0-9_]+)\\b$/);
  if (single) {
    return [single[1]];
  }

  throw new Error(`unsupported word-pattern shape for ${label}: ${patternSource}`);
}

function duplicates(values) {
  const seen = new Set();
  const repeated = [];

  values.forEach((value) => {
    if (seen.has(value) && !repeated.includes(value)) {
      repeated.push(value);
      return;
    }

    seen.add(value);
  });

  return repeated;
}

function diffSet(expectedValues, actualValues) {
  const expected = new Set(expectedValues);
  const actual = new Set(actualValues);

  return {
    missing: expectedValues.filter((value) => !actual.has(value)),
    extra: actualValues.filter((value) => !expected.has(value)),
  };
}

function formatWordList(values) {
  return values.map((value) => `    - ${value}`).join('\n');
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function main() {
  const grammar = JSON.parse(readText(GRAMMAR_PATH));
  const tokenSource = readText(TOKEN_PATH);
  const typesSource = readText(TYPES_PATH);
  const lspSource = readText(LSP_PATH);

  const tokenKeywords = extractRubyHashKeys(tokenSource, 'KEYWORDS');
  const configuredKeywordGroups = [
    ...CONTROL_KEYWORD_WORDS,
    ...OPERATOR_KEYWORD_WORDS,
    ...MODIFIER_KEYWORD_WORDS,
    ...CONSTANT_LANGUAGE_WORDS,
  ];
  const unknownConfiguredKeywords = configuredKeywordGroups.filter((keyword) => !tokenKeywords.includes(keyword) && !CONTEXTUAL_KEYWORDS.has(keyword));

  if (unknownConfiguredKeywords.length) {
    fail([
      'Milk Tea tmLanguage sync check failed.',
      '',
      'keyword category constants mention non-keywords:',
      formatWordList(unknownConfiguredKeywords),
    ].join('\n'));
  }

  const primitiveTypes = extractRubyPercentW(typesSource, 'BUILTIN_PRIMITIVE_NAMES');
  const builtinFunctions = extractRubyPercentW(lspSource, 'BUILTIN_FUNCTION_NAMES')
    .filter((name) => !TEXTMATE_BUILTIN_EXCLUSIONS.has(name));

  const expectedDeclarationKeywords = tokenKeywords.filter((keyword) => {
    return !CONTROL_KEYWORD_WORDS.includes(keyword) &&
      !OPERATOR_KEYWORD_WORDS.includes(keyword) &&
      !MODIFIER_KEYWORD_WORDS.includes(keyword) &&
      !CONSTANT_LANGUAGE_WORDS.includes(keyword);
  });

  const actualKeywordControl = extractWordPatternWords(grammar.repository['keyword-control'].match, 'keyword-control');
  const actualKeywordDeclaration = extractWordPatternWords(grammar.repository['keyword-declaration'].match, 'keyword-declaration');
  const actualKeywordOperator = extractWordPatternWords(grammar.repository['keyword-operator'].match, 'keyword-operator');
  const actualKeywordModifier = extractWordPatternWords(grammar.repository['keyword-modifier'].match, 'keyword-modifier');
  const actualKeywordBuiltin = extractWordPatternWords(grammar.repository['keyword-builtin'].match, 'keyword-builtin');
  const actualPrimitiveTypes = extractWordPatternWords(grammar.repository['type-primitive'].match, 'type-primitive');

  const actualConstantLanguage = grammar.repository['constant-language'].patterns.flatMap((pattern) => {
    return extractWordPatternWords(pattern.match, `constant-language:${pattern.name}`);
  });

  const checks = [
    { name: '$schema', expected: [EXPECTED_SCHEMA_URL], actual: [grammar.$schema || '<missing>'] },
    { name: 'keyword-control', expected: CONTROL_KEYWORD_WORDS, actual: actualKeywordControl },
    { name: 'keyword-declaration', expected: expectedDeclarationKeywords, actual: actualKeywordDeclaration },
    { name: 'keyword-operator', expected: OPERATOR_KEYWORD_WORDS, actual: actualKeywordOperator },
    { name: 'keyword-modifier', expected: MODIFIER_KEYWORD_WORDS, actual: actualKeywordModifier },
    { name: 'keyword-builtin', expected: builtinFunctions, actual: actualKeywordBuiltin },
    { name: 'type-primitive', expected: primitiveTypes, actual: actualPrimitiveTypes },
    { name: 'constant-language', expected: [...CONSTANT_LANGUAGE_WORDS, ...SPECIAL_LANGUAGE_WORDS], actual: actualConstantLanguage },
  ];

  const failures = [];

  checks.forEach(({ name, expected, actual }) => {
    const repeated = duplicates(actual);
    const { missing, extra } = diffSet(expected, actual);
    if (repeated.length || missing.length || extra.length) {
      failures.push({ name, repeated, missing, extra });
    }
  });

  if (failures.length) {
    const lines = ['Milk Tea tmLanguage sync check failed.'];
    failures.forEach(({ name, repeated, missing, extra }) => {
      lines.push(``);
      lines.push(`${name}:`);
      if (repeated.length) {
        lines.push('  duplicate entries:');
        lines.push(formatWordList(repeated));
      }
      if (missing.length) {
        lines.push('  missing entries:');
        lines.push(formatWordList(missing));
      }
      if (extra.length) {
        lines.push('  unexpected entries:');
        lines.push(formatWordList(extra));
      }
    });

    fail(lines.join('\n'));
  }

  process.stdout.write('Milk Tea tmLanguage sync check passed.\n');
}

main();
