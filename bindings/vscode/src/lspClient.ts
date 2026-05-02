import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
  Trace,
  RevealOutputChannelOn,
} from 'vscode-languageclient/node';
import { getConfig } from './config';
import type { Logger } from './log';

export class MilkTeaLspClient {
  private client: LanguageClient | undefined;
  private readonly log: Logger;
  private readonly traceChannel: vscode.OutputChannel;
  private startPromise: Promise<void> | undefined;

  constructor(log: Logger, traceChannel: vscode.OutputChannel) {
    this.log          = log;
    this.traceChannel = traceChannel;
  }

  get isRunning(): boolean {
    return this.client !== undefined;
  }

  async start(): Promise<void> {
    if (this.client) {
      this.log.warn('LSP client is already running; call restart() to reset it.');
      return;
    }

    const cfg = getConfig().lsp;
    if (!cfg.enabled) {
      this.log.info('LSP is disabled in settings (milkTea.lsp.enabled = false).');
      return;
    }

    const args = ['lsp', ...cfg.extraArgs];
    this.log.info(`Starting LSP server: ${cfg.serverPath} ${args.join(' ')}`);

    const serverOptions: ServerOptions = {
      command: cfg.serverPath,
      args,
      transport: TransportKind.stdio,
    };

    const clientOptions: LanguageClientOptions = {
      documentSelector: [
        { scheme: 'file',      language: 'milk-tea' },
        { scheme: 'untitled',  language: 'milk-tea' },
      ],
      // Main output channel — used for server stderr and our own log messages.
      outputChannel: {
        name:        'Milk Tea LSP',
        append:      (value: string) => this.log.appendLine(value),
        appendLine:  (value: string) => this.log.appendLine(value),
        clear:       () => { /* no-op */ },
        replace:     () => { /* no-op */ },
        show:        () => this.log.show(),
        hide:        () => { /* no-op */ },
        dispose:     () => { /* no-op */ },
      } satisfies vscode.OutputChannel,
      // Secondary channel for raw JSON-RPC trace.
      traceOutputChannel: this.traceChannel,
      revealOutputChannelOn: RevealOutputChannelOn.Error,
      synchronize: {
        fileEvents: vscode.workspace.createFileSystemWatcher('**/*.mt'),
      },
    };

    this.client = new LanguageClient(
      'milk-tea-lsp',
      'Milk Tea LSP',
      serverOptions,
      clientOptions,
    );

    // Apply trace level from config.
    await this.applyTrace(this.client, cfg.traceServer);

    try {
      await this.client.start();
      this.log.info('LSP server started successfully.');
    } catch (err) {
      this.log.error(`Failed to start LSP server: ${err}`);
      this.client = undefined;
      throw err;
    }

    // Watch for future config changes.
    this.startPromise = undefined;
  }

  async stop(): Promise<void> {
    if (!this.client) { return; }
    this.log.info('Stopping LSP server…');
    try {
      await this.client.stop();
      this.log.info('LSP server stopped.');
    } catch (err) {
      this.log.warn(`Error stopping LSP server: ${err}`);
    } finally {
      this.client = undefined;
    }
  }

  async restart(): Promise<void> {
    this.log.info('Restarting LSP server…');
    await this.stop();
    await this.start();
  }

  // Called when workspace config changes so trace level stays in sync.
  async syncTrace(): Promise<void> {
    if (!this.client) { return; }
    const cfg = getConfig().lsp;
    await this.applyTrace(this.client, cfg.traceServer);
  }

  private async applyTrace(
    client: LanguageClient,
    level: 'off' | 'messages' | 'verbose',
  ): Promise<void> {
    const trace: Trace =
      level === 'verbose'  ? Trace.Verbose  :
      level === 'messages' ? Trace.Messages :
      Trace.Off;
    await client.setTrace(trace);
  }
}
