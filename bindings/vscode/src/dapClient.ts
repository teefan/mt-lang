import * as vscode from 'vscode';
import { getConfig } from './config';
import type { Logger } from './log';

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
    const args = [...cfg.extraArgs];

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
  private readonly retryAttemptsByKey = new Map<string, number>();
  private readonly explicitStops = new Set<string>();
  private readonly log: Logger;

  constructor(log: Logger) {
    this.log = log;
  }

  register(context: vscode.ExtensionContext): void {
    context.subscriptions.push(
      vscode.debug.onDidStartDebugSession((session) => {
        if (session.type === 'milk-tea') {
          this.sessions.add(session);
          this.sessionStarts.set(session.id, Date.now());
          this.log.info(`DAP session started: '${session.name}' (id=${session.id})`);
        }
      }),
      vscode.debug.onDidTerminateDebugSession(async (session) => {
        if (this.sessions.delete(session)) {
          const startMs = this.sessionStarts.get(session.id) ?? Date.now();
          this.sessionStarts.delete(session.id);
          this.log.info(`DAP session ended: '${session.name}' (id=${session.id})`);

          if (this.explicitStops.delete(session.id)) {
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
        await vscode.debug.stopDebugging(session);
      } catch (err) {
        this.log.warn(`Could not stop session '${session.name}': ${err}`);
      }
    }
  }
}
