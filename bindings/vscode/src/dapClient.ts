import * as vscode from 'vscode';
import { getConfig } from './config';
import type { Logger } from './log';

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
    const args = ['dap', ...cfg.extraArgs];

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
  private readonly log: Logger;

  constructor(log: Logger) {
    this.log = log;
  }

  register(context: vscode.ExtensionContext): void {
    context.subscriptions.push(
      vscode.debug.onDidStartDebugSession((session) => {
        if (session.type === 'milk-tea') {
          this.sessions.add(session);
          this.log.info(`DAP session started: '${session.name}' (id=${session.id})`);
        }
      }),
      vscode.debug.onDidTerminateDebugSession((session) => {
        if (this.sessions.delete(session)) {
          this.log.info(`DAP session ended: '${session.name}' (id=${session.id})`);
        }
      }),
    );
  }

  async stopAll(): Promise<void> {
    if (this.sessions.size === 0) {
      this.log.info('No active Milk Tea DAP sessions to stop.');
      return;
    }

    this.log.info(`Stopping ${this.sessions.size} active DAP session(s)…`);
    for (const session of [...this.sessions]) {
      try {
        await vscode.debug.stopDebugging(session);
      } catch (err) {
        this.log.warn(`Could not stop session '${session.name}': ${err}`);
      }
    }
  }
}
