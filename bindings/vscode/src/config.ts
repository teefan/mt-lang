import * as vscode from 'vscode';

export type LogLevel = 'off' | 'error' | 'warn' | 'info' | 'debug' | 'trace';

export interface MilkTeaConfig {
  lsp: {
    enabled: boolean;
    serverPath: string;
    extraArgs: string[];
    logLevel: LogLevel;
    traceServer: 'off' | 'messages' | 'verbose';
  };
  dap: {
    enabled: boolean;
    serverPath: string;
    extraArgs: string[];
  };
}

export function getConfig(): MilkTeaConfig {
  const cfg = vscode.workspace.getConfiguration('milkTea');
  return {
    lsp: {
      enabled:     cfg.get<boolean>('lsp.enabled', true),
      serverPath:  cfg.get<string>('lsp.serverPath', 'mtc'),
      extraArgs:   cfg.get<string[]>('lsp.extraArgs', []),
      logLevel:    cfg.get<LogLevel>('lsp.logLevel', 'info'),
      traceServer: cfg.get<'off' | 'messages' | 'verbose'>('lsp.traceServer', 'off'),
    },
    dap: {
      enabled:    cfg.get<boolean>('dap.enabled', true),
      serverPath: cfg.get<string>('dap.serverPath', 'mtc'),
      extraArgs:  cfg.get<string[]>('dap.extraArgs', []),
    },
  };
}
