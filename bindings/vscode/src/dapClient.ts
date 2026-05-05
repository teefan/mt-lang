import * as vscode from 'vscode';
import { getConfig } from './config';
import type { Logger } from './log';

type DapProtocolMessage = {
  type?: string;
  seq?: unknown;
  command?: unknown;
  event?: unknown;
  request_seq?: unknown;
  success?: unknown;
  arguments?: unknown;
  body?: unknown;
  message?: unknown;
};

type SessionConfiguration = {
  request?: string;
  backend?: string;
  program?: string;
  cwd?: string;
  args?: unknown;
  noDebug?: boolean;
  stopOnEntry?: boolean;
  adapterPath?: string;
  pid?: unknown;
  processName?: string;
  waitFor?: boolean;
  sourceMap?: unknown;
  env?: Record<string, unknown>;
  preInitCommands?: unknown;
  initCommands?: unknown;
  preRunCommands?: unknown;
  postRunCommands?: unknown;
  coreFile?: string;
};

const IMPORTANT_DAP_COMMANDS = new Set([
  'initialize',
  'launch',
  'attach',
  'setBreakpoints',
  'setFunctionBreakpoints',
  'setExceptionBreakpoints',
  'configurationDone',
  'continue',
  'next',
  'stepIn',
  'stepOut',
  'threads',
  'stackTrace',
  'scopes',
  'variables',
  'disconnect',
]);

const IMPORTANT_DAP_EVENTS = new Set([
  'initialized',
  'capabilities',
  'stopped',
  'continued',
  'output',
  'terminated',
  'exited',
]);

const REDACTED_KEY_PATTERN = /(token|secret|password|passwd|authorization|api[-_]?key|access[-_]?key)/i;

function delayMs(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Each debug session spins up a fresh `mtc dap` process via stdio.
// The factory is registered once; VS Code calls createDebugAdapterDescriptor
// for every new debug session.
export class MilkTeaDebugAdapterFactory
  implements vscode.DebugAdapterDescriptorFactory
{
  private readonly log: Logger;

  constructor(log: Logger) {
    this.log = log;
  }

  createDebugAdapterDescriptor(
    session: vscode.DebugSession,
    _executable: vscode.DebugAdapterExecutable | undefined,
  ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
    const cfg  = getConfig().dap;
    const sessionCfg = session.configuration as SessionConfiguration;
    const backend = typeof sessionCfg.backend === 'string' && sessionCfg.backend.trim().length > 0
      ? sessionCfg.backend.trim()
      : 'lldb-dap';

    const args = [`--backend=${backend}`, ...cfg.extraArgs];
    if (typeof sessionCfg.adapterPath === 'string' && sessionCfg.adapterPath.trim().length > 0) {
      args.unshift(`--adapter-path=${sessionCfg.adapterPath.trim()}`);
    }

    this.log.info(
      `DAP session '${session.name}' starting: ${cfg.serverPath} ${args.join(' ')}`,
    );

    const cwd = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    const options: vscode.DebugAdapterExecutableOptions = cwd !== undefined ? { cwd } : {};
    return new vscode.DebugAdapterExecutable(cfg.serverPath, args, options);
  }
}

// Tracks active debug sessions for the "restart DAP" command.
export class MilkTeaDapSessionTracker {
  private readonly sessions = new Set<vscode.DebugSession>();
  private readonly sessionStarts = new Map<string, number>();
  private readonly sessionExited = new Set<string>();
  private readonly sessionExitCodes = new Map<string, number | undefined>();
  private readonly retryAttemptsByKey = new Map<string, number>();
  private readonly explicitStops = new Set<string>();
  private readonly sessionShutdownExpected = new Set<string>();
  private readonly log: Logger;

  constructor(log: Logger) {
    this.log = log;
  }

  register(context: vscode.ExtensionContext): void {
    context.subscriptions.push(
      vscode.debug.registerDebugAdapterTrackerFactory('milk-tea', {
        createDebugAdapterTracker: (session) => ({
          onWillStartSession: () => {
            this.log.debug(`DAP tracker attached: '${session.name}' (id=${session.id})`);
          },
          onWillReceiveMessage: (message: unknown) => {
            this.noteExpectedShutdownFromClientMessage(session, message);
            this.logProtocolMessage(session, 'client->adapter', message);
          },
          onDidSendMessage: (message: unknown) => {
            const msg = message as DapProtocolMessage;
            this.logProtocolMessage(session, 'adapter->client', msg);

            if (msg?.type !== 'event') {
              if (msg?.type === 'response' && msg.success === false) {
                this.log.error(
                  `DAP response failure for '${session.name}': ${JSON.stringify(this.summarizeProtocolMessage(msg))}`,
                );
              }
              return;
            }

            if (msg.event === 'exited') {
              this.sessionShutdownExpected.add(session.id);
              this.sessionExited.add(session.id);
              const body = msg.body && typeof msg.body === 'object'
                ? msg.body as { exitCode?: unknown }
                : undefined;
              const rawCode = body?.exitCode;
              const exitCode = typeof rawCode === 'number' ? rawCode : undefined;
              this.sessionExitCodes.set(session.id, exitCode);
            } else if (msg.event === 'terminated') {
              this.sessionShutdownExpected.add(session.id);
            }
          },
          onWillStopSession: () => {
            this.log.debug(`DAP tracker stopping: '${session.name}' (id=${session.id})`);
          },
          onError: (error: Error) => {
            if (this.shouldSuppressAdapterShutdownNoise(session.id, error.message)) {
              this.log.debug(`Suppressing benign DAP adapter error for '${session.name}': ${error.message}`);
              return;
            }
            this.log.error(`DAP adapter error for '${session.name}': ${error.message}`);
          },
          onExit: (code: number | undefined, signal: string | undefined) => {
            if (this.shouldSuppressAdapterShutdownNoise(session.id)) {
              this.log.debug(
                `Suppressing benign DAP adapter exit for '${session.name}': code=${typeof code === 'number' ? code : 'undefined'}, signal=${signal ?? 'undefined'}`,
              );
              return;
            }
            this.log.warn(
              `DAP adapter process exited for '${session.name}': code=${typeof code === 'number' ? code : 'undefined'}, signal=${signal ?? 'undefined'}`,
            );
          },
        }),
      }),

      vscode.debug.onDidStartDebugSession((session) => {
        if (session.type === 'milk-tea') {
          this.sessions.add(session);
          this.sessionStarts.set(session.id, Date.now());
          this.sessionShutdownExpected.delete(session.id);
          this.sessionExited.delete(session.id);
          this.sessionExitCodes.delete(session.id);
          this.log.info(`DAP session started: '${session.name}' (id=${session.id})`);
          this.log.info(
            `DAP config for '${session.name}': ${JSON.stringify(this.summarizeSessionConfiguration(session.configuration as SessionConfiguration))}`,
          );
        }
      }),
      vscode.debug.onDidTerminateDebugSession(async (session) => {
        if (this.sessions.delete(session)) {
          const startMs = this.sessionStarts.get(session.id) ?? Date.now();
          this.sessionStarts.delete(session.id);
          this.sessionShutdownExpected.delete(session.id);
          const sawExitedEvent = this.sessionExited.delete(session.id);
          const exitCode = this.sessionExitCodes.get(session.id);
          this.sessionExitCodes.delete(session.id);
          this.log.info(`DAP session ended: '${session.name}' (id=${session.id})`);

          if (this.explicitStops.delete(session.id)) {
            return;
          }

          // If the debug adapter reported a normal process exit, do not retry.
          // This covers user-initiated window closes and successful short runs.
          if (sawExitedEvent) {
            this.retryAttemptsByKey.delete(this.retryKey(session));
            if (typeof exitCode === 'number') {
              this.log.info(
                `DAP session '${session.name}' exited with code ${exitCode}; skipping auto-retry.`,
              );
            } else {
              this.log.info(
                `DAP session '${session.name}' exited normally; skipping auto-retry.`,
              );
            }
            return;
          }

          const cfg = getConfig().dap.retry;
          if (!cfg.enabled) {
            return;
          }

          const elapsedMs = Date.now() - startMs;
          const quickFailureMs = 5000;
          if (elapsedMs >= quickFailureMs) {
            this.retryAttemptsByKey.delete(this.retryKey(session));
            return;
          }

          const key = this.retryKey(session);
          const usedAttempts = this.retryAttemptsByKey.get(key) ?? 1;
          const maxAttempts = Math.max(1, cfg.maxAttempts);

          if (usedAttempts >= maxAttempts) {
            this.retryAttemptsByKey.delete(key);
            void vscode.window.showErrorMessage(
              `Milk Tea: DAP failed to connect after ${maxAttempts} attempts. ` +
              'Check milkTea.dap.serverPath and view DAP logs.',
              'View DAP Logs',
            ).then((action) => {
              if (action === 'View DAP Logs') {
                this.log.show(false);
              }
            });
            return;
          }

          const nextAttempt = usedAttempts + 1;
          this.retryAttemptsByKey.set(key, nextAttempt);

          const delaySeconds = Math.max(1, cfg.delaySeconds);
          this.log.warn(
            `DAP session '${session.name}' ended too quickly; retrying ` +
            `(${nextAttempt}/${maxAttempts}) in ${delaySeconds}s.`,
          );

          void vscode.window.showWarningMessage(
            `Milk Tea: DAP connection failed. Retrying ${nextAttempt}/${maxAttempts} in ${delaySeconds}s...`,
          );

          await delayMs(delaySeconds * 1000);
          await vscode.debug.startDebugging(session.workspaceFolder, session.configuration);
        }
      }),
    );
  }

  private retryKey(session: vscode.DebugSession): string {
    const cfg = session.configuration as { name?: string; program?: string; cwd?: string };
    return [cfg.name ?? session.name, cfg.program ?? '', cfg.cwd ?? ''].join('|');
  }

  async stopAll(): Promise<void> {
    if (this.sessions.size === 0) {
      this.log.info('No active Milk Tea DAP sessions to stop.');
      return;
    }

    this.log.info(`Stopping ${this.sessions.size} active DAP session(s)…`);
    for (const session of [...this.sessions]) {
      try {
        this.explicitStops.add(session.id);
        this.sessionShutdownExpected.add(session.id);
        await vscode.debug.stopDebugging(session);
      } catch (err) {
        this.log.warn(`Could not stop session '${session.name}': ${err}`);
      }
    }
  }

  private logProtocolMessage(
    session: vscode.DebugSession,
    direction: 'client->adapter' | 'adapter->client',
    message: unknown,
  ): void {
    const summary = this.summarizeProtocolMessage(message);
    if (!summary) {
      return;
    }

    if (this.log.allows('trace')) {
      this.log.trace(`DAP ${direction} '${session.name}': ${JSON.stringify(this.sanitizeForLog(message))}`);
      return;
    }

    if (this.log.allows('debug')) {
      this.log.debug(`DAP ${direction} '${session.name}': ${JSON.stringify(summary)}`);
      return;
    }

    if (this.isImportantProtocolMessage(message)) {
      this.log.info(`DAP ${direction} '${session.name}': ${JSON.stringify(summary)}`);
    }
  }

  private isImportantProtocolMessage(message: unknown): boolean {
    const msg = message as DapProtocolMessage | undefined;
    if (!msg || typeof msg !== 'object') {
      return false;
    }

    if (msg.type === 'request') {
      return IMPORTANT_DAP_COMMANDS.has(String(msg.command ?? ''));
    }

    if (msg.type === 'response') {
      return msg.success === false || IMPORTANT_DAP_COMMANDS.has(String(msg.command ?? ''));
    }

    if (msg.type === 'event') {
      return IMPORTANT_DAP_EVENTS.has(String(msg.event ?? ''));
    }

    return false;
  }

  private noteExpectedShutdownFromClientMessage(
    session: vscode.DebugSession,
    message: unknown,
  ): void {
    const msg = message as DapProtocolMessage | undefined;
    if (!msg || typeof msg !== 'object' || msg.type !== 'request') {
      return;
    }

    const command = String(msg.command ?? '');
    if (command === 'terminate' || command === 'disconnect') {
      this.sessionShutdownExpected.add(session.id);
    }
  }

  private shouldSuppressAdapterShutdownNoise(sessionId: string, message?: string): boolean {
    if (!this.sessionShutdownExpected.has(sessionId) && !this.sessionExited.has(sessionId)) {
      return false;
    }

    if (message === undefined) {
      return true;
    }

    return message.trim().toLowerCase() === 'read error';
  }

  private summarizeProtocolMessage(message: unknown): Record<string, unknown> | undefined {
    const msg = message as DapProtocolMessage | undefined;
    if (!msg || typeof msg !== 'object') {
      return undefined;
    }

    switch (msg.type) {
      case 'request':
        return {
          type: 'request',
          seq: this.compactValue(msg.seq),
          command: this.compactValue(msg.command),
          arguments: this.compactValue(msg.arguments),
        };
      case 'response':
        return {
          type: 'response',
          seq: this.compactValue(msg.seq),
          request_seq: this.compactValue(msg.request_seq),
          command: this.compactValue(msg.command),
          success: this.compactValue(msg.success),
          message: this.compactValue(msg.message),
          body: this.compactValue(msg.body),
        };
      case 'event':
        return {
          type: 'event',
          seq: this.compactValue(msg.seq),
          event: this.compactValue(msg.event),
          body: this.compactValue(msg.body),
        };
      default:
        return {
          type: this.compactValue(msg.type),
          payload: this.compactValue(msg),
        };
    }
  }

  private summarizeSessionConfiguration(config: SessionConfiguration): Record<string, unknown> {
    const envKeys = config.env && typeof config.env === 'object'
      ? Object.keys(config.env).sort()
      : [];
    const sourceMapKeys = config.sourceMap && typeof config.sourceMap === 'object'
      ? Object.keys(config.sourceMap as Record<string, unknown>).sort()
      : [];

    return {
      request: config.request ?? undefined,
      backend: config.backend ?? undefined,
      program: config.program ?? undefined,
      cwd: config.cwd ?? undefined,
      args: this.compactValue(config.args),
      noDebug: config.noDebug ?? undefined,
      stopOnEntry: config.stopOnEntry ?? undefined,
      adapterPath: config.adapterPath ?? undefined,
      pid: this.compactValue(config.pid),
      processName: config.processName ?? undefined,
      waitFor: config.waitFor ?? undefined,
      coreFile: config.coreFile ?? undefined,
      sourceMapKeys,
      envKeys,
      preInitCommands: this.compactValue(config.preInitCommands),
      initCommands: this.compactValue(config.initCommands),
      preRunCommands: this.compactValue(config.preRunCommands),
      postRunCommands: this.compactValue(config.postRunCommands),
    };
  }

  private isSensitiveKey(key: string): boolean {
    return REDACTED_KEY_PATTERN.test(key);
  }

  private compactRedactedEnv(entry: Record<string, unknown>): string[] {
    return Object.keys(entry).sort().map((envKey) => `${envKey}=[REDACTED]`);
  }

  private sanitizeRedactedEnv(entry: Record<string, unknown>): Record<string, string> {
    return Object.fromEntries(
      Object.keys(entry).sort().map((envKey) => [envKey, '[REDACTED]']),
    );
  }

  private compactValue(value: unknown, depth = 0): unknown {
    if (value === null || value === undefined) {
      return value;
    }

    if (typeof value === 'string') {
      return value.length > 160 ? `${value.slice(0, 160)}...` : value;
    }

    if (typeof value !== 'object') {
      return value;
    }

    if (depth >= 3) {
      return Array.isArray(value) ? `[Array(${value.length})]` : '[Object]';
    }

    if (Array.isArray(value)) {
      const items = value.slice(0, 8).map((entry) => this.compactValue(entry, depth + 1));
      if (value.length > items.length) {
        items.push(`... +${value.length - items.length} more`);
      }
      return items;
    }

    const result: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value)) {
      if (key === 'env' && entry && typeof entry === 'object') {
        result[key] = this.compactRedactedEnv(entry as Record<string, unknown>);
        continue;
      }

      if (this.isSensitiveKey(key)) {
        result[key] = '[REDACTED]';
        continue;
      }

      result[key] = this.compactValue(entry, depth + 1);
    }

    return result;
  }

  private sanitizeForLog(value: unknown): unknown {
    if (value === null || value === undefined) {
      return value;
    }

    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
      return value;
    }

    if (Array.isArray(value)) {
      return value.map((entry) => this.sanitizeForLog(entry));
    }

    if (typeof value === 'object') {
      const result: Record<string, unknown> = {};
      for (const [key, entry] of Object.entries(value)) {
        if (key === 'env' && entry && typeof entry === 'object') {
          result[key] = this.sanitizeRedactedEnv(entry as Record<string, unknown>);
          continue;
        }

        if (this.isSensitiveKey(key)) {
          result[key] = '[REDACTED]';
          continue;
        }

        result[key] = this.sanitizeForLog(entry);
      }

      return result;
    }

    return String(value);
  }
}
