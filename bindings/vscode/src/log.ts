import * as vscode from 'vscode';
import type { LogLevel } from './config';

const LEVEL_RANK: Record<LogLevel, number> = {
  off:   0,
  error: 1,
  warn:  2,
  info:  3,
  debug: 4,
  trace: 5,
};

export class Logger {
  private readonly channel: vscode.OutputChannel;
  private level: LogLevel;

  constructor(channel: vscode.OutputChannel, level: LogLevel = 'info') {
    this.channel = channel;
    this.level   = level;
  }

  setLevel(level: LogLevel): void {
    this.level = level;
  }

  show(preserveFocus = true): void {
    this.channel.show(preserveFocus);
  }

  hide(): void {
    this.channel.hide();
  }

  dispose(): void {
    this.channel.dispose();
  }

  error(msg: string): void { this.write('error', msg); }
  warn(msg:  string): void { this.write('warn',  msg); }
  info(msg:  string): void { this.write('info',  msg); }
  debug(msg: string): void { this.write('debug', msg); }
  trace(msg: string): void { this.write('trace', msg); }

  // Append raw text (used for LSP protocol traces).
  appendLine(line: string): void {
    this.channel.appendLine(line);
  }

  private write(level: LogLevel, msg: string): void {
    if (this.level === 'off') { return; }
    if (LEVEL_RANK[level] > LEVEL_RANK[this.level]) { return; }
    const ts    = new Date().toISOString();
    const label = level.toUpperCase().padEnd(5);
    this.channel.appendLine(`[${ts}] [${label}] ${msg}`);
  }
}
