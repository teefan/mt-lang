import * as vscode from 'vscode';

export type LogLevel = 'off' | 'error' | 'warn' | 'info' | 'debug' | 'trace';

export interface RetryConfig {
  enabled: boolean;
  maxAttempts: number;
  delaySeconds: number;
}

export interface MilkTeaConfig {
  lsp: {
    enabled: boolean;
    serverPath: string;
    extraArgs: string[];
    logLevel: LogLevel;
    traceServer: 'off' | 'messages' | 'verbose';
    retry: RetryConfig;
  };
  dap: {
    enabled: boolean;
    serverPath: string;
    extraArgs: string[];
    retry: RetryConfig;
  };
}

export function getConfig(): MilkTeaConfig {
  const cfg = vscode.workspace.getConfiguration('milkTea');
  return {
    lsp: {
      enabled:     cfg.get<boolean>('lsp.enabled', true),
      serverPath:  cfg.get<string>('lsp.serverPath', 'mtc-lsp'),
      extraArgs:   cfg.get<string[]>('lsp.extraArgs', []),
      logLevel:    cfg.get<LogLevel>('lsp.logLevel', 'info'),
      traceServer: cfg.get<'off' | 'messages' | 'verbose'>('lsp.traceServer', 'off'),
      retry: {
        enabled:     cfg.get<boolean>('lsp.retry.enabled', true),
        maxAttempts: cfg.get<number>('lsp.retry.maxAttempts', 3),
        delaySeconds: cfg.get<number>('lsp.retry.delaySeconds', 10),
      },
    },
    dap: {
      enabled:    cfg.get<boolean>('dap.enabled', true),
      serverPath: cfg.get<string>('dap.serverPath', 'mtc-dap'),
      extraArgs:  cfg.get<string[]>('dap.extraArgs', []),
      retry: {
        enabled:      cfg.get<boolean>('dap.retry.enabled', true),
        maxAttempts:  cfg.get<number>('dap.retry.maxAttempts', 3),
        delaySeconds: cfg.get<number>('dap.retry.delaySeconds', 10),
      },
    },
  };
}
