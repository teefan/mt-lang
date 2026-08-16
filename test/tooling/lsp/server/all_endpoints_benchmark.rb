#!/usr/bin/env ruby
# frozen_string_literal: true

# LSP All-Endpoints Performance Benchmark
#
# Exercises every handler registered in MilkTea::LSP::Server#register_handlers
# against a synthetic multi-module workspace and reports per-endpoint latency.
#
# Run: ruby test/tooling/lsp/server/all_endpoints_benchmark.rb
#   --perf     also sets MILK_TEA_LSP_PERF=verbose to surface stage breakdowns
#   --iters N  override the iteration count for lightweight endpoints

require "tmpdir"
require "cgi/escape"
require "json"

PERF_ENABLED = ARGV.include?("--perf")
if (idx = ARGV.index("--iters")) && ARGV[idx + 1]
  ITERATIONS_DEFAULT = Integer(ARGV[idx + 1])
else
  ITERATIONS_DEFAULT = 10
end
ARGV.delete("--perf")
ARGV.delete_at(idx) if (idx = ARGV.index("--iters")) && ARGV[idx + 1]
ARGV.delete_at(idx) if (idx = ARGV.index("--iters")) && ARGV[idx + 1]

ENV["MILK_TEA_LSP_PERF"] = "verbose" if PERF_ENABLED

require_relative "helpers"

module AllEndpointsBenchmark
  def self.path_to_uri(path)
    "file://#{path.split('/').map { |seg| CGI.escape(seg).gsub('+', '%20') }.join('/')}"
  end

  MAIN_SOURCE = <<~MT
    import mod_alpha as alpha
    import mod_beta as beta

    ## A sample struct.
    ## @param x the x value
    struct Sample:
        x: int
        y: int

    extending Sample:
        function sum() -> int:
            return this.x + this.y

    interface Shape:
        function area() -> float

    struct Circle implements Shape:
        radius: float

    extending Circle:
        function area() -> float:
            return 3.14159 * this.radius * this.radius

    enum Color:
        red
        green
        blue

    variant Token:
        ident(text: str)
        eof

    function compute(a: int, b: int) -> int:
        return a + b

    function main() -> int:
        var total: int = 0
        let s = Sample(x = 1, y = 2)
        total += s.sum()
        total += compute(3, 4)
        total += alpha.fn_alpha(10)
        let c = Circle(radius = 1.0)
        let area = c.area()
        let _a = area
        let asset = "assets/file.txt"
        let _asset = asset
        return total
  MT

  ALPHA_SOURCE = <<~MT
    ## Alpha helper module.
    public function fn_alpha(value: int) -> int:
        return value * 2

    public struct Widget:
        size: int

    extending Widget:
        function grow() -> int:
            return this.size + 1
  MT

  BETA_SOURCE = <<~MT
    ## Beta helper module.
    public function fn_beta(value: int) -> int:
        return value + 3
  MT

  SCRATCH_SOURCE = <<~MT
    function scratch_fn() -> int:
        return 1
  MT

  # Build the synthetic workspace on disk and return file paths.
  def self.build_workspace(dir)
    alpha_dir = File.join(dir, "mod_alpha")
    beta_dir = File.join(dir, "mod_beta")
    assets_dir = File.join(dir, "assets")
    Dir.mkdir(alpha_dir)
    Dir.mkdir(beta_dir)
    Dir.mkdir(assets_dir)

    alpha_path = File.join(alpha_dir, "lib.mt")
    beta_path = File.join(beta_dir, "lib.mt")
    main_path = File.join(dir, "main.mt")
    scratch_path = File.join(dir, "scratch.mt")
    asset_path = File.join(assets_dir, "file.txt")

    File.write(alpha_path, ALPHA_SOURCE)
    File.write(beta_path, BETA_SOURCE)
    File.write(main_path, MAIN_SOURCE)
    File.write(scratch_path, SCRATCH_SOURCE)
    File.write(asset_path, "hello\n")

    { alpha: alpha_path, beta: beta_path, main: main_path, scratch: scratch_path }
  end

  # Locate the 0-based (line, char) of a marker substring in +source+.
  def self.find_pos(source, marker, within: nil)
    lines = source.split("\n", -1)
    line_idx = if within
                 lines.index { |l| l.include?(marker) && l.include?(within) }
               else
                 lines.index { |l| l.include?(marker) }
               end
    return nil unless line_idx

    col = lines[line_idx].index(marker)
    return nil unless col

    [line_idx, col]
  end

  # Return the position at +marker+ plus +offset+ columns.
  def self.find_pos_offset(source, marker, offset)
    line, col = find_pos(source, marker)
    return nil unless line && col

    [line, col + offset]
  end
end

def time_calls(iterations)
  times = []
  iterations.times do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
  end
  times
end

def summarize(times)
  return { avg: 0.0, min: 0.0, max: 0.0 } if times.empty?

  {
    avg: times.sum / times.length,
    min: times.min,
    max: times.max,
  }
end

def run_all_endpoints_benchmark(iterations_default:)
  results = []
  errors = []

  Dir.mktmpdir("mt-lsp-all-endpoints") do |dir|
    files = AllEndpointsBenchmark.build_workspace(dir)
    main_path = files[:main]
    main_uri = AllEndpointsBenchmark.path_to_uri(main_path)
    main_source = AllEndpointsBenchmark::MAIN_SOURCE

    protocol = LSPServerTestHelpers::RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)
    # Stop diagnostics workers so queued didOpen/didChange work cannot perturb
    # subsequent latency measurements (schedule_diagnostics stays synchronous).
    server.send(:stop_diagnostics_workers)

    ws = server.instance_variable_get(:@workspace)

    text_doc = { "textDocument" => { "uri" => main_uri } }
    pos = lambda { |line, char| { "textDocument" => { "uri" => main_uri }, "position" => { "line" => line, "character" => char } } }

    measure = lambda do |label, iters, **opts|
      warmup = opts.fetch(:warmup, true)
      block = opts[:call]
      result = opts[:result]
      raise "measure requires :call" unless block

      begin
        block.call if warmup
        times = time_calls(iters) { block.call }
        stats = summarize(times)
        results << { label: label, iters: iters, avg: stats[:avg], min: stats[:min], max: stats[:max], result: result&.call }
      rescue StandardError => e
        errors << { label: label, error: "#{e.class}: #{e.message}", backtrace: e.backtrace.first(4) }
        results << { label: label, iters: iters, avg: nil, min: nil, max: nil, result: "ERROR: #{e.class}" }
      end
    end

    # ── Lifecycle ─────────────────────────────────────────────────────────
    measure.call("initialize", 1, warmup: false, call: lambda {
      server.send(:handle_initialize, { "rootUri" => AllEndpointsBenchmark.path_to_uri(dir), "capabilities" => {} })
    }, result: lambda { "ok" })

    # ── Open documents (via workspace directly to avoid background diagnostics) ──
    server.send(:handle_initialized, {})
    server.instance_variable_get(:@_indexing_thread)&.join

    ws.open_document(main_uri, main_source)
    ws.open_document(AllEndpointsBenchmark.path_to_uri(files[:alpha]), AllEndpointsBenchmark::ALPHA_SOURCE)
    ws.open_document(AllEndpointsBenchmark.path_to_uri(files[:beta]), AllEndpointsBenchmark::BETA_SOURCE)

    # Locate interesting positions in main.mt.
    compute_pos = AllEndpointsBenchmark.find_pos(main_source, "compute(3, 4)")
    compute_name_pos = AllEndpointsBenchmark.find_pos(main_source, "compute(")
    sample_pos = AllEndpointsBenchmark.find_pos(main_source, "Sample(x = 1")
    shape_pos = AllEndpointsBenchmark.find_pos(main_source, "Shape")
    circle_pos = AllEndpointsBenchmark.find_pos(main_source, "Circle(radius = 1.0")
    total_pos = AllEndpointsBenchmark.find_pos_offset(main_source, "var total: int = 0", "var ".length)
    main_fn_pos = AllEndpointsBenchmark.find_pos_offset(main_source, "function main()", "function ".length)
    sig_pos = AllEndpointsBenchmark.find_pos_offset(main_source, "compute(3, 4)", "compute(".length)

    # ── Position-based request endpoints ───────────────────────────────────
    measure.call("textDocument/hover", iterations_default, call: lambda {
      server.send(:handle_hover, pos.call(*compute_name_pos))
    }, result: lambda { "hover" })

    measure.call("textDocument/definition", iterations_default, call: lambda {
      server.send(:handle_definition, pos.call(*compute_pos))
    }, result: lambda { "location" })

    measure.call("textDocument/declaration", iterations_default, call: lambda {
      server.send(:handle_declaration, pos.call(*compute_pos))
    }, result: lambda { "location" })

    measure.call("textDocument/typeDefinition", iterations_default, call: lambda {
      server.send(:handle_type_definition, pos.call(*sample_pos))
    }, result: lambda { "location" })

    measure.call("textDocument/implementation", iterations_default, call: lambda {
      server.send(:handle_implementation, pos.call(*shape_pos))
    }, result: lambda { "locations" })

    measure.call("textDocument/references", iterations_default, call: lambda {
      server.send(:handle_references, pos.call(*compute_pos).merge("context" => { "includeDeclaration" => true }))
    }, result: lambda { "refs" })

    measure.call("textDocument/documentHighlight", iterations_default, call: lambda {
      server.send(:handle_document_highlight, pos.call(*total_pos))
    }, result: lambda { "ranges" })

    measure.call("textDocument/documentSymbol", iterations_default, call: lambda {
      server.send(:handle_document_symbols, text_doc)
    }, result: lambda { "symbols" })

    measure.call("textDocument/foldingRange", iterations_default, call: lambda {
      server.send(:handle_folding_range, text_doc)
    }, result: lambda { "folds" })

    measure.call("textDocument/selectionRange", iterations_default, call: lambda {
      server.send(:handle_selection_range, { "textDocument" => { "uri" => main_uri }, "positions" => [pos.call(*compute_pos)["position"]] })
    }, result: lambda { "ranges" })

    measure.call("textDocument/completion", iterations_default, call: lambda {
      server.send(:handle_completion, pos.call(0, 0))
    }, result: lambda { "items" })

    # Inside the main body (not an import line) exercises the global completion
    # path rather than the module-root filesystem scan.
    body_pos = AllEndpointsBenchmark.find_pos(main_source, "var total: int = 0")
    measure.call("textDocument/completion (body)", iterations_default, call: lambda {
      server.send(:handle_completion, pos.call(*body_pos))
    }, result: lambda { "items" })

    measure.call("textDocument/signatureHelp", iterations_default, call: lambda {
      server.send(:handle_signature_help, pos.call(*sig_pos))
    }, result: lambda { "signatures" })

    measure.call("textDocument/prepareRename", iterations_default, call: lambda {
      server.send(:handle_prepare_rename, pos.call(*total_pos))
    }, result: lambda { "range" })

    measure.call("textDocument/rename", iterations_default, call: lambda {
      server.send(:handle_rename, pos.call(*total_pos).merge("newName" => "total2"))
    }, result: lambda { "changes" })

    measure.call("textDocument/linkedEditingRange", iterations_default, call: lambda {
      server.send(:handle_linked_editing_range, pos.call(*total_pos))
    }, result: lambda { "ranges" })

    measure.call("textDocument/inlayHint", iterations_default, call: lambda {
      server.send(:handle_inlay_hint, text_doc.merge("range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => main_source.count("\n"), "character" => 0 } }))
    }, result: lambda { "hints" })

    measure.call("textDocument/semanticTokens/full", 3, call: lambda {
      server.send(:handle_semantic_tokens_full, text_doc)
    }, result: lambda { "tokens" })

    measure.call("textDocument/semanticTokens/range", iterations_default, call: lambda {
      server.send(:handle_semantic_tokens_range, text_doc.merge("range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 12, "character" => 0 } }))
    }, result: lambda { "tokens" })

    measure.call("textDocument/codeLens", iterations_default, call: lambda {
      server.send(:handle_code_lens, text_doc)
    }, result: lambda { "lenses" })

    measure.call("textDocument/codeAction", iterations_default, call: lambda {
      server.send(:handle_code_action, text_doc.merge("context" => { "diagnostics" => [], "only" => ["quickFix"] }))
    }, result: lambda { "actions" })

    measure.call("textDocument/documentLink", iterations_default, call: lambda {
      server.send(:handle_document_link, text_doc)
    }, result: lambda { "links" })

    measure.call("textDocument/prepareCallHierarchy", iterations_default, call: lambda {
      server.send(:handle_prepare_call_hierarchy, pos.call(*main_fn_pos))
    }, result: lambda { "item" })

    measure.call("textDocument/prepareTypeHierarchy", iterations_default, call: lambda {
      server.send(:handle_prepare_type_hierarchy, pos.call(*shape_pos))
    }, result: lambda { "item" })

    measure.call("textDocument/diagnostic", 1, call: lambda {
      server.send(:handle_document_diagnostic, text_doc)
    }, result: lambda { "diagnostics" })

    measure.call("workspace/diagnostic", 1, call: lambda {
      server.send(:handle_workspace_diagnostic, {})
    }, result: lambda { "items" })

    # ── Chained endpoints (resolve / delta / hierarchy follow-ups) ─────────
    call_item = server.send(:handle_prepare_call_hierarchy, pos.call(*main_fn_pos)).first
    if call_item
      measure.call("callHierarchy/incomingCalls", iterations_default, call: lambda {
        server.send(:handle_incoming_calls, { "item" => call_item })
      }, result: lambda { "callers" })
      measure.call("callHierarchy/outgoingCalls", iterations_default, call: lambda {
        server.send(:handle_outgoing_calls, { "item" => call_item })
      }, result: lambda { "callees" })
    end

    type_item = server.send(:handle_prepare_type_hierarchy, pos.call(*shape_pos)).first
    if type_item
      measure.call("typeHierarchy/subtypes", iterations_default, call: lambda {
        server.send(:handle_subtypes, { "item" => type_item })
      }, result: lambda { "subtypes" })
    end

    circle_item = server.send(:handle_prepare_type_hierarchy, pos.call(*circle_pos)).first
    if circle_item
      measure.call("typeHierarchy/supertypes", iterations_default, call: lambda {
        server.send(:handle_supertypes, { "item" => circle_item })
      }, result: lambda { "supertypes" })
    end

    lens = server.send(:handle_code_lens, text_doc).first
    if lens
      measure.call("codeLens/resolve", iterations_default, call: lambda {
        server.send(:handle_code_lens_resolve, lens)
      }, result: lambda { "command" })
    end

    comp_item = server.send(:handle_completion, pos.call(0, 0))[:items].first
    if comp_item
      measure.call("completionItem/resolve", iterations_default, call: lambda {
        server.send(:handle_completion_resolve, comp_item)
      }, result: lambda { "item" })
    end

    link = server.send(:handle_document_link, text_doc).first
    if link
      measure.call("documentLink/resolve", iterations_default, call: lambda {
        server.send(:handle_document_link_resolve, link)
      }, result: lambda { "link" })
    end

    sem_full = server.send(:handle_semantic_tokens_full, text_doc)
    prev_result_id = sem_full[:resultId]
    measure.call("textDocument/semanticTokens/full/delta", 3, call: lambda {
      server.send(:handle_semantic_tokens_delta, text_doc.merge("previousResultId" => prev_result_id))
    }, result: lambda { "edits" })

    # ── Formatting ─────────────────────────────────────────────────────────
    measure.call("textDocument/formatting", 3, call: lambda {
      server.send(:handle_formatting, text_doc.merge("options" => { "tabSize" => 4, "insertSpaces" => true }))
    }, result: lambda { "edits" })

    measure.call("textDocument/rangeFormatting", iterations_default, call: lambda {
      server.send(:handle_range_formatting, text_doc.merge("range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 8, "character" => 0 } }, "options" => { "tabSize" => 4, "insertSpaces" => true }))
    }, result: lambda { "edits" })

    measure.call("textDocument/onTypeFormatting", iterations_default, call: lambda {
      server.send(:handle_on_type_formatting, text_doc.merge("position" => { "line" => 26, "character" => 0 }, "ch" => "\n"))
    }, result: lambda { "edits" })

    measure.call("textDocument/willSaveWaitUntil", iterations_default, call: lambda {
      server.send(:handle_will_save_wait_until, text_doc)
    }, result: lambda { "edits" })

    # ── Diagnostics scheduling (synchronous part) ──────────────────────────
    measure.call("textDocument/didOpen", iterations_default, call: lambda {
      server.send(:handle_did_open, { "textDocument" => { "uri" => AllEndpointsBenchmark.path_to_uri(files[:scratch]), "languageId" => "milk-tea", "version" => 1, "text" => AllEndpointsBenchmark::SCRATCH_SOURCE } })
    }, result: lambda { "opened" })

    measure.call("textDocument/didChange", iterations_default, call: lambda {
      server.send(:handle_did_change, { "textDocument" => { "uri" => AllEndpointsBenchmark.path_to_uri(files[:scratch]), "version" => 2 }, "contentChanges" => [{ "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 0, "character" => 0 } }, "text" => "  " }] })
    }, result: lambda { "changed" })

    measure.call("textDocument/didClose", iterations_default, call: lambda {
      server.send(:handle_did_close, { "textDocument" => { "uri" => AllEndpointsBenchmark.path_to_uri(files[:scratch]) } })
    }, result: lambda { "closed" })

    measure.call("textDocument/didSave", iterations_default, call: lambda {
      server.send(:handle_did_save, text_doc)
    }, result: lambda { "saved" })

    measure.call("milkTea/documentContext", iterations_default, call: lambda {
      server.send(:handle_document_context, { "textDocument" => { "uri" => main_uri }, "source" => "active-editor" })
    }, result: lambda { "ok" })

    measure.call("milkTea/debugInfo", 1, call: lambda {
      server.send(:handle_debug_info, text_doc)
    }, result: lambda { "text" })

    # ── Workspace endpoints ────────────────────────────────────────────────
    measure.call("workspace/symbol", 3, call: lambda {
      server.send(:handle_workspace_symbol, { "query" => "" })
    }, result: lambda { "symbols" })

    measure.call("workspace/executeCommand", iterations_default, call: lambda {
      server.send(:handle_execute_command, { "command" => "mtc.nonexistent" })
    }, result: lambda { "nil" })

    measure.call("workspace/didChangeConfiguration", iterations_default, call: lambda {
      server.send(:handle_did_change_configuration, { "settings" => { "milkTea" => { "format" => { "mode" => "tidy" } } } })
    }, result: lambda { "nil" })

    measure.call("workspace/didChangeWorkspaceFolders", iterations_default, call: lambda {
      server.send(:handle_did_change_workspace_folders, { "event" => { "added" => [], "removed" => [] } })
    }, result: lambda { "nil" })

    measure.call("workspace/didChangeWatchedFiles", iterations_default, call: lambda {
      server.send(:handle_did_change_watched_files, { "changes" => [{ "uri" => main_uri, "type" => 1 }] })
    }, result: lambda { "nil" })

    measure.call("workspace/willRenameFiles", iterations_default, call: lambda {
      server.send(:handle_will_rename_files, { "files" => [] })
    }, result: lambda { "nil" })

    measure.call("$/cancelRequest", iterations_default, call: lambda {
      server.send(:handle_cancel_request, { "id" => 99_999 })
    }, result: lambda { "nil" })

    server.send(:handle_shutdown, {})
  end

  [results, errors]
end

if __FILE__ == $PROGRAM_NAME
  results, errors = run_all_endpoints_benchmark(iterations_default: ITERATIONS_DEFAULT)

  puts "=" * 88
  puts "LSP All-Endpoints Benchmark (iters=#{ITERATIONS_DEFAULT})"
  puts "=" * 88
  puts format("%-46s %6s %10s %10s %10s  %s", "endpoint", "iters", "avg ms", "min ms", "max ms", "result")
  puts "-" * 88

  results.sort_by { |r| r[:avg] || Float::INFINITY }.reverse_each do |r|
    avg = r[:avg] ? format("%.2f", r[:avg]) : "--"
    min = r[:min] ? format("%.2f", r[:min]) : "--"
    max = r[:max] ? format("%.2f", r[:max]) : "--"
    puts format("%-46s %6d %10s %10s %10s  %s", r[:label], r[:iters], avg, min, max, r[:result])
  end

  puts "-" * 88
  total_avg = results.sum { |r| r[:avg] || 0.0 }
  puts format("%-46s %10.2f", "TOTAL avg (single pass over all endpoints)", total_avg)

  unless errors.empty?
    puts ""
    puts "Errors:"
    errors.each do |e|
      puts "  #{e[:label]}: #{e[:error]}"
      e[:backtrace]&.each { |line| puts "    #{line}" }
    end
  end
end
