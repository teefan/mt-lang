#!/usr/bin/env ruby
# frozen_string_literal: true

# LSP Performance Benchmark
# Run: ruby test/tooling/lsp/server/benchmark.rb [--after]

require_relative "helpers"

require "tmpdir"
require "cgi/escape"
require "json"
require "benchmark"

module BenchmarkHelpers
  def self.path_to_uri(path)
    "file://#{path.split('/').map { |seg| CGI.escape(seg).gsub('+', '%20') }.join('/')}"
  end
end

def build_synthetic_workspace(dir, num_files: 50, funcs_per_file: 20)
  files = []
  num_files.times do |fi|
    dirname = File.join(dir, "mod_#{fi}")
    Dir.mkdir(dirname)
    path = File.join(dirname, "lib.mt")
    source = "public module mod_#{fi}\n\n"
    funcs_per_file.times do |fi2|
      source += "public function func_#{fi}_#{fi2}(a: int, b: int) -> int:\n"
      source += "    return a + b\n\n"
    end
    File.write(path, source)
    files << path
  end

  main_path = File.join(dir, "main.mt")
  imports = files.map.with_index { |f, i| "import mod_#{i}.lib as m#{i}" }.join("\n")
  main_source = "struct Sample:\n    x: int\n\n#{imports}\n\n"
  main_source += "function main() -> int:\n    let x = m0.func_0_0(1, 2)\n    return x\n"
  File.write(main_path, main_source)
  { files: files, main: main_path }
end

def run_benchmarks(label)
  puts "=" * 60
  puts "LSP Performance Benchmark: #{label}"
  puts "=" * 60

  Dir.mktmpdir("mt-lsp-perf") do |dir|
    workspace = build_synthetic_workspace(dir)

    protocol = LSPServerTestHelpers::RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)
    begin
      ws = server.instance_variable_get(:@workspace)
      main_uri = BenchmarkHelpers.path_to_uri(workspace[:main])

      comp_iters = 50
      ref_iters = 20
      def_iters = 10
      hov_iters = 10

      puts "\n[Warming up: opening #{workspace[:files].length + 1} files...]"
      warmup_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ws.open_document(main_uri, File.read(workspace[:main]))
      workspace[:files].each do |path|
        uri = BenchmarkHelpers.path_to_uri(path)
        ws.open_document(uri, File.read(path))
      end
      warmup_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - warmup_start) * 1000).round(1)
      puts "  Warmup: #{warmup_ms}ms"

      main_src = File.read(workspace[:main])
      func_line = main_src.lines.index { |l| l.include?("func_0_0") } || 0
      func_char = main_src.lines[func_line]&.index("func_0_0") || 0

      # Completion
      puts "\n--- Completion (#{comp_iters} iterations) ---"
      comp_time = Benchmark.measure {
        comp_iters.times do
          server.send(:handle_completion, {
            "textDocument" => { "uri" => main_uri },
            "position" => { "line" => 0, "character" => 0 },
          })
        end
      }
      puts "  Total: #{comp_time.real.round(3)}s, Avg: #{(comp_time.real / comp_iters * 1000).round(2)}ms"
      result = server.send(:handle_completion, {
        "textDocument" => { "uri" => main_uri },
        "position" => { "line" => 0, "character" => 0 },
      })
      comp_items = result[:items].length
      puts "  Items: #{comp_items}"

      # References
      puts "\n--- References (#{ref_iters} iterations) ---"
      ref_time = Benchmark.measure {
        ref_iters.times do
          server.send(:handle_references, {
            "textDocument" => { "uri" => main_uri },
            "position" => { "line" => func_line, "character" => func_char + 2 },
            "context" => { "includeDeclaration" => true },
          })
        end
      }
      puts "  Total: #{ref_time.real.round(3)}s, Avg: #{(ref_time.real / ref_iters * 1000).round(2)}ms"

      # Definition
      puts "\n--- Definition (#{def_iters} iterations) ---"
      def_time = Benchmark.measure {
        def_iters.times do
          server.send(:handle_definition_request, "textDocument/definition", {
            "textDocument" => { "uri" => main_uri },
            "position" => { "line" => func_line, "character" => func_char + 2 },
          }, error_label: "perf")
        end
      }
      puts "  Total: #{def_time.real.round(3)}s, Avg: #{(def_time.real / def_iters * 1000).round(2)}ms"

      # Hover
      puts "\n--- Hover (#{hov_iters} iterations) ---"
      hov_time = Benchmark.measure {
        hov_iters.times do
          server.send(:handle_hover, {
            "textDocument" => { "uri" => main_uri },
            "position" => { "line" => func_line, "character" => func_char + 2 },
          })
        end
      }
      puts "  Total: #{hov_time.real.round(3)}s, Avg: #{(hov_time.real / hov_iters * 1000).round(2)}ms"

      # Semantic Tokens
      puts "\n--- Semantic Tokens (3 iterations) ---"
      sem_time = Benchmark.measure {
        3.times do
          server.send(:handle_semantic_tokens_full, {
            "textDocument" => { "uri" => main_uri },
          })
        end
      }
      puts "  Total: #{sem_time.real.round(3)}s, Avg: #{(sem_time.real / 3 * 1000).round(2)}ms"

      return {
        warmup_ms: warmup_ms,
        completion_ms: (comp_time.real / comp_iters * 1000).round(2),
        completion_items: comp_items,
        references_ms: (ref_time.real / ref_iters * 1000).round(2),
        definition_ms: (def_time.real / def_iters * 1000).round(2),
        hover_ms: (hov_time.real / hov_iters * 1000).round(2),
        semtokens_ms: (sem_time.real / 3 * 1000).round(2),
      }
    ensure
      server&.send(:stop_diagnostics_workers)
    end
  end
rescue StandardError => e
  puts "ERROR: #{e.message}"
  puts e.backtrace.first(8).join("\n")
  nil
end

stats = run_benchmarks(ARGV.include?("--after") ? "AFTER fixes" : "BEFORE fixes")
if stats
  puts "\n--- Summary ---"
  puts "Warmup:            #{stats[:warmup_ms]}ms"
  puts "Completion avg:    #{stats[:completion_ms]}ms (#{stats[:completion_items]} items)"
  puts "References avg:    #{stats[:references_ms]}ms"
  puts "Definition avg:    #{stats[:definition_ms]}ms"
  puts "Hover avg:         #{stats[:hover_ms]}ms"
  puts "SemanticTokens avg: #{stats[:semtokens_ms]}ms"
end
