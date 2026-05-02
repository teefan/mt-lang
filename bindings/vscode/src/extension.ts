import * as vscode from 'vscode';
import { getConfig }                from './config';
import { Logger }                   from './log';
import { MilkTeaLspClient }         from './lspClient';
import { MilkTeaDebugAdapterFactory, MilkTeaDapSessionTracker } from './dapClient';

// ---------------------------------------------------------------------------
// Output channels (created once, live for the extension lifetime)
// ---------------------------------------------------------------------------

let lspLogger:    Logger | undefined;
let dapLogger:    Logger | undefined;
let traceChannel: vscode.OutputChannel | undefined;

// ---------------------------------------------------------------------------
// activate
// ---------------------------------------------------------------------------

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  // ── Output channels ────────────────────────────────────────────────────
  const lspChannel = vscode.window.createOutputChannel('Milk Tea LSP',  'milk-tea');
  const dapChannel = vscode.window.createOutputChannel('Milk Tea DAP',  'milk-tea');
  traceChannel     = vscode.window.createOutputChannel('Milk Tea LSP Trace');

  context.subscriptions.push(lspChannel, dapChannel, traceChannel);

  const cfg   = getConfig();
  lspLogger   = new Logger(lspChannel, cfg.lsp.logLevel);
  dapLogger   = new Logger(dapChannel, 'info');

  lspLogger.info('Milk Tea extension activating…');

  // ── LSP client ─────────────────────────────────────────────────────────
  const lspClient = new MilkTeaLspClient(lspLogger, traceChannel);
  context.subscriptions.push({ dispose: () => void lspClient.stop() });

  // ── DAP factory + session tracker ──────────────────────────────────────
  const dapTracker = new MilkTeaDapSessionTracker(dapLogger);
  dapTracker.register(context);

  // ── Commands ───────────────────────────────────────────────────────────
  context.subscriptions.push(
    vscode.commands.registerCommand('milk-tea.showSignature', (signature?: unknown) => {
      const text = typeof signature === 'string' && signature.trim().length > 0
        ? signature
        : 'Function signature';
      void vscode.window.showInformationMessage(text);
    }),

    vscode.commands.registerCommand('milkTea.restartLsp', async () => {
      await lspClient.restart().catch((err: unknown) => {
        void vscode.window.showErrorMessage(`Milk Tea: LSP restart failed — ${err}`);
      });
      void vscode.window.showInformationMessage('Milk Tea: LSP restarted.');
    }),

    vscode.commands.registerCommand('milkTea.viewLspLogs', () => {
      lspLogger?.show(false);
    }),

    vscode.commands.registerCommand('milkTea.viewDapLogs', () => {
      dapLogger?.show(false);
    }),

    vscode.commands.registerCommand('milkTea.restartDap', async () => {
      await dapTracker.stopAll();
      void vscode.window.showInformationMessage(
        'Milk Tea: All active DAP sessions stopped. Start a new debug session to reconnect.',
      );
    }),
  );

  if (cfg.lsp.enabled) {
    void lspClient.startWithRetry({
      onRetrying: (attempt, maxAttempts, delaySeconds, err) => {
        void vscode.window.showWarningMessage(
          `Milk Tea: LSP start failed. Retrying ${attempt}/${maxAttempts} in ${delaySeconds}s...`,
        );
        lspLogger?.warn(
          `LSP startup retry scheduled (${attempt}/${maxAttempts}) in ${delaySeconds}s: ${err}`,
        );
      },
      onExhausted: (maxAttempts, err) => {
        lspLogger?.error(`LSP startup failed after ${maxAttempts} attempts: ${err}`);
      },
    }).catch((err: unknown) => {
      void vscode.window.showErrorMessage(
        `Milk Tea: failed to start LSP server after retries — ${err}. ` +
        `Check milkTea.lsp.serverPath and try "Milk Tea: Restart LSP".`,
      );
    });
  }

  if (cfg.dap.enabled) {
    const dapFactory = new MilkTeaDebugAdapterFactory(dapLogger);
    context.subscriptions.push(
      vscode.debug.registerDebugAdapterDescriptorFactory('milk-tea', dapFactory),
    );
    dapLogger.info('DAP factory registered for type "milk-tea".');
  } else {
    dapLogger.info('DAP is disabled in settings (milkTea.dap.enabled = false).');
  }

  // ── Watch for config changes ────────────────────────────────────────────
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration(async (event) => {
      if (!event.affectsConfiguration('milkTea')) { return; }

      const newCfg = getConfig();

      // Update log level live — no restart needed.
      lspLogger?.setLevel(newCfg.lsp.logLevel);

      // Sync trace level to running client.
      if (lspClient.isRunning) {
        await lspClient.syncTrace();
      }

      // If the server path or enabled flag changed, offer a restart.
      if (
        event.affectsConfiguration('milkTea.lsp.serverPath') ||
        event.affectsConfiguration('milkTea.lsp.enabled')    ||
        event.affectsConfiguration('milkTea.lsp.extraArgs')  ||
        event.affectsConfiguration('milkTea.lsp.retry.enabled') ||
        event.affectsConfiguration('milkTea.lsp.retry.maxAttempts') ||
        event.affectsConfiguration('milkTea.lsp.retry.delaySeconds')
      ) {
        const action = await vscode.window.showInformationMessage(
          'Milk Tea: LSP configuration changed. Restart the language server?',
          'Restart',
          'Later',
        );
        if (action === 'Restart') {
          await lspClient.restart().catch((err: unknown) => {
            void vscode.window.showErrorMessage(`Milk Tea: LSP restart failed — ${err}`);
          });
        }
      }

      if (
        event.affectsConfiguration('milkTea.dap.retry.enabled') ||
        event.affectsConfiguration('milkTea.dap.retry.maxAttempts') ||
        event.affectsConfiguration('milkTea.dap.retry.delaySeconds')
      ) {
        void vscode.window.showInformationMessage(
          'Milk Tea: DAP retry configuration changed. New values apply to future debug sessions.',
        );
      }
    }),
  );

  lspLogger.info('Milk Tea extension activated.');
}

// ---------------------------------------------------------------------------
// deactivate
// ---------------------------------------------------------------------------

export function deactivate(): void {
  // LSP client disposal is handled by the subscription registered in activate().
  // Output channels are also disposed via subscriptions.
}
