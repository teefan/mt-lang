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

interface RetryEvents {
  onRetrying?: (attempt: number, maxAttempts: number, delaySeconds: number, error: unknown) => void;
  onExhausted?: (maxAttempts: number, error: unknown) => void;
}

function delayMs(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class MilkTeaLspClient {
  private static readonly DOCUMENT_CONTEXT_METHOD = 'milkTea/documentContext';

  private client: LanguageClient | undefined;
  private readonly log: Logger;
  private readonly traceChannel: vscode.OutputChannel;
  private startPromise: Promise<void> | undefined;
  private readonly traceDisposables: vscode.Disposable[] = [];

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

    const args = [...cfg.extraArgs];
    this.log.info(`Starting LSP server: ${cfg.serverPath} ${args.join(' ')}`);
    this.installClientTracing();

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
      middleware: this.createTracingMiddleware(),
      synchronize: {
        fileEvents: vscode.workspace.createFileSystemWatcher('**/*.mt'),
      },
      initializationOptions: {
        milkTea: { format: { mode: getConfig().format.mode } },
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
      this.disposeClientTracing();
      this.client = undefined;
      throw err;
    }

    // Watch for future config changes.
    this.startPromise = undefined;
  }

  async startWithRetry(events?: RetryEvents): Promise<void> {
    const cfg = getConfig().lsp;
    if (!cfg.enabled) {
      this.log.info('LSP is disabled in settings (milkTea.lsp.enabled = false).');
      return;
    }

    const maxAttempts = Math.max(1, cfg.retry.maxAttempts);
    const delaySeconds = Math.max(1, cfg.retry.delaySeconds);
    const retriesEnabled = cfg.retry.enabled;

    let lastError: unknown;

    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        await this.start();
        return;
      } catch (error) {
        lastError = error;
        const hasNextAttempt = retriesEnabled && attempt < maxAttempts;
        if (!hasNextAttempt) {
          break;
        }

        events?.onRetrying?.(attempt + 1, maxAttempts, delaySeconds, error);
        await delayMs(delaySeconds * 1000);
      }
    }

    if (lastError !== undefined) {
      events?.onExhausted?.(maxAttempts, lastError);
      throw lastError;
    }
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
      this.disposeClientTracing();
      this.client = undefined;
    }
  }

  async restart(): Promise<void> {
    this.log.info('Restarting LSP server…');
    await this.stop();
    await this.startWithRetry();
  }

  // Called when format mode config changes — no restart needed.
  async syncFormatMode(): Promise<void> {
    if (!this.client) { return; }
    const mode = getConfig().format.mode;
    await this.client.sendNotification('workspace/didChangeConfiguration', {
      settings: { milkTea: { format: { mode } } },
    });
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

  private createTracingMiddleware(): NonNullable<LanguageClientOptions['middleware']> {
    return {
      didOpen: async (document, next) => {
        await this.syncDocumentContext(document);
        await next(document);
      },

      didChange: async (event, next) => {
        await this.syncDocumentContext(event.document);
        await next(event);
      },

      provideDocumentSemanticTokens: (document, token, next) => (
        this.traceFeatureRequest(
          'semanticTokens/full',
          document,
          () => next(document, token),
          {},
          { backgroundResult: new vscode.SemanticTokens(new Uint32Array()) },
        )
      ),

      provideDocumentSemanticTokensEdits: (document, previousResultId, token, next) => (
        this.traceFeatureRequest(
          'semanticTokens/edits',
          document,
          () => next(document, previousResultId, token),
          { previousResultId },
          { backgroundResult: new vscode.SemanticTokens(new Uint32Array()) },
        )
      ),

      provideInlayHints: (document, viewPort, token, next) => (
        this.traceFeatureRequest(
          'inlayHint',
          document,
          () => next(document, viewPort, token),
          { range: viewPort },
          { backgroundResult: [] },
        )
      ),

      provideHover: (document, position, token, next) => (
        this.traceFeatureRequest(
          'hover',
          document,
          () => next(document, position, token),
          { position },
          { backgroundResult: undefined },
        )
      ),

      provideDefinition: (document, position, token, next) => (
        this.traceFeatureRequest(
          'definition',
          document,
          () => next(document, position, token),
          { position },
          { backgroundResult: undefined },
        )
      ),
    };
  }

  private installClientTracing(): void {
    this.disposeClientTracing();

    this.traceDisposables.push(
      vscode.workspace.onDidOpenTextDocument((document) => {
        if (!this.isTrackedMilkTeaDocument(document)) {
          return;
        }

        this.traceClient(`document open ${this.describeDocumentContext(document)}`);
      }),
      vscode.workspace.onDidCloseTextDocument((document) => {
        if (!this.isTrackedMilkTeaDocument(document)) {
          return;
        }

        this.traceClient(`document close ${this.describeDocumentContext(document)}`);
      }),
    );

    const activeEditor = vscode.window.activeTextEditor;
    if (activeEditor && this.isTrackedMilkTeaDocument(activeEditor.document)) {
      this.traceClient(`session active ${this.describeDocumentContext(activeEditor.document)}`);
    }
  }

  private disposeClientTracing(): void {
    while (this.traceDisposables.length > 0) {
      this.traceDisposables.pop()?.dispose();
    }
  }

  private traceFeatureRequest<T>(
    feature: string,
    document: vscode.TextDocument,
    next: () => vscode.ProviderResult<T>,
    context: {
      position?: vscode.Position;
      range?: vscode.Range;
      previousResultId?: string;
    } = {},
    options: {
      backgroundResult?: T;
    } = {},
  ): Promise<T | null | undefined> {
    const startedAt = Date.now();
    const detail = this.describeFeatureContext(document, context);
    const stackHint = this.captureStackHint();
    this.traceClient(`feature ${feature} start ${detail}${stackHint ? ` stack_hint=${stackHint}` : ''}`);

    return this.syncDocumentContext(document).then(() => {
      if (this.documentSourceHint(document) === 'background-document') {
        this.traceClient(
          `feature ${feature} skip ${Date.now() - startedAt}ms ${detail} reason=background-document`,
        );
        return options.backgroundResult;
      }

      try {
        const result = next();
        return Promise.resolve(result).then(
          (value) => {
            this.traceClient(
              `feature ${feature} done ${Date.now() - startedAt}ms ${detail} result=${this.describeFeatureResult(feature, value)}`,
            );
            return value;
          },
          (error) => {
            this.traceClient(
              `feature ${feature} error ${Date.now() - startedAt}ms ${detail} error=${this.describeError(error)}`,
            );
            throw error;
          },
        );
      } catch (error) {
        this.traceClient(
          `feature ${feature} error ${Date.now() - startedAt}ms ${detail} error=${this.describeError(error)}`,
        );
        throw error;
      }
    });
  }

  private async syncDocumentContext(document: vscode.TextDocument): Promise<void> {
    if (!this.client || !this.isTrackedMilkTeaDocument(document)) {
      return;
    }

    await this.client.sendNotification(MilkTeaLspClient.DOCUMENT_CONTEXT_METHOD, {
      textDocument: { uri: document.uri.toString() },
      source: this.documentSourceHint(document),
    });
  }

  private traceClient(message: string): void {
    const ts = new Date().toISOString();
    this.traceChannel.appendLine(`[${ts}] [client] ${message}`);
    if (this.log.allows('debug')) {
      this.log.debug(`[client] ${message}`);
    }
  }

  private isTrackedMilkTeaDocument(document: vscode.TextDocument): boolean {
    return document.languageId === 'milk-tea' && (document.uri.scheme === 'file' || document.uri.scheme === 'untitled');
  }

  private describeFeatureContext(
    document: vscode.TextDocument,
    context: {
      position?: vscode.Position;
      range?: vscode.Range;
      previousResultId?: string;
    },
  ): string {
    const bits = [this.describeDocumentContext(document)];

    if (context.position) {
      bits.push(`position=${context.position.line + 1}:${context.position.character + 1}`);
    }

    if (context.range) {
      bits.push(
        `range=${context.range.start.line + 1}:${context.range.start.character + 1}-${context.range.end.line + 1}:${context.range.end.character + 1}`,
      );
    }

    if (context.previousResultId) {
      bits.push(`previous_result_id=${context.previousResultId}`);
    }

    return bits.join(' ');
  }

  private describeDocumentContext(document: vscode.TextDocument): string {
    const bits = [
      `uri=${this.shortenUri(document.uri)}`,
      `source=${this.documentSourceHint(document)}`,
      `scheme=${document.uri.scheme}`,
      `version=${document.version}`,
      `dirty=${document.isDirty}`,
    ];

    return bits.join(' ');
  }

  private documentSourceHint(document: vscode.TextDocument): string {
    const activeUri = vscode.window.activeTextEditor?.document.uri.toString();
    if (activeUri === document.uri.toString()) {
      return 'active-editor';
    }

    const isVisible = vscode.window.visibleTextEditors.some((editor) => editor.document.uri.toString() === document.uri.toString());
    return isVisible ? 'visible-editor' : 'background-document';
  }

  private shortenUri(uri: vscode.Uri): string {
    if (uri.scheme !== 'file') {
      return uri.toString(true);
    }

    const folder = vscode.workspace.getWorkspaceFolder(uri);
    if (!folder) {
      return uri.fsPath;
    }

    const relativePath = vscode.workspace.asRelativePath(uri, false);
    return relativePath || uri.fsPath;
  }

  private captureStackHint(): string | undefined {
    const stack = new Error().stack;
    if (!stack) {
      return undefined;
    }

    const frames = stack
      .split('\n')
      .slice(2)
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .filter((line) => !line.includes('src/lspClient.ts'))
      .filter((line) => !line.includes('dist/lspClient.js'))
      .filter((line) => !line.includes('vscode-languageclient'))
      .filter((line) => !line.includes('node:internal'))
      .filter((line) => line.includes('/.vscode/extensions/') || line.includes('/extensions/') || line.includes('/dist/') || line.includes('/out/'))
      .slice(0, 3)
      .map((line) => this.sanitizeStackFrame(line));

    return frames.length > 0 ? frames.join(' <= ') : undefined;
  }

  private sanitizeStackFrame(frame: string): string {
    return frame.replace(/\s+/g, ' ').trim();
  }

  private describeFeatureResult(feature: string, value: unknown): string {
    if (feature.startsWith('semanticTokens')) {
      if (value instanceof vscode.SemanticTokens) {
        return `tokens=${value.data.length}`;
      }
      if (value instanceof vscode.SemanticTokensEdits) {
        return `edits=${value.edits.length}`;
      }
    }

    if (feature === 'inlayHint') {
      return Array.isArray(value) ? `hints=${value.length}` : 'hints=none';
    }

    if (feature === 'hover') {
      return value ? 'hover=hit' : 'hover=none';
    }

    if (feature === 'definition') {
      if (Array.isArray(value)) {
        return `definitions=${value.length}`;
      }
      return value ? 'definitions=1' : 'definitions=0';
    }

    return value == null ? 'result=none' : 'result=present';
  }

  private describeError(error: unknown): string {
    if (error instanceof Error) {
      return error.message;
    }

    return String(error);
  }
}
