#!/usr/bin/env ruby
# frozen_string_literal: true

# Long-session soak: drive mixed LSP requests (edits, semantic tokens,
# diagnostics, references, hover) against one server and report its RSS over
# time.  The plan's C4 target (≥5k lines, ≥10k requests, mixed methods) is
# `--cycles 2500`; the gates run a short meter and compare the printed slope
# against the recorded one (see docs/self-host-plan.md §0k session 30).
#
# Usage: ruby tools/lsp_soak.rb [--bin BIN] [--cycles N] [--mode full|tokens|diag|refs]
#                               [--workspace DIR] [--file REL] [--label NAME] [--quiet]

require "cgi/escape"
require "json"
require "fileutils"
require "timeout"

ROOT = File.expand_path("..", __dir__)

def path_to_uri(path)
  "file://#{path.split("/").map { |seg| CGI.escape(seg).gsub("+", "%20") }.join("/")}"
end

bin = File.join(ROOT, "build", "stage2", "mtc")
cycles = 200
label = nil
workspace = File.join(ROOT, "tmp", "soak-ws")
file = "main.mt"
quiet = false
mode = "full"

i = 0
while i < ARGV.length
  case ARGV[i]
  when "--bin" then bin = ARGV[i + 1]; i += 2
  when "--cycles" then cycles = ARGV[i + 1].to_i; i += 2
  when "--label" then label = ARGV[i + 1]; i += 2
  when "--workspace" then workspace = File.expand_path(ARGV[i + 1]); i += 2
  when "--file" then file = ARGV[i + 1]; i += 2
  when "--quiet" then quiet = true; i += 1
  when "--mode" then mode = ARGV[i + 1]; i += 2
  else abort "unknown option #{ARGV[i]}"
  end
end
abort "unknown mode #{mode}" unless %w[full tokens diag refs steady].include?(mode)

## Generate the synthetic workspace once: ~5k lines of declarations plus two
## ~500-line modules with cross references.
def generate_workspace(workspace)
  main_path = File.join(workspace, "main.mt")
  return if File.exist?(main_path)

  FileUtils.mkdir_p(workspace)
  lib_a = +"public struct Point:\n    x: int\n    y: int\n\n"
  lib_b = +"public const SCALE: int = 3\n\n"
  120.times do |n|
    lib_a << "public function helper_#{n}(p: Point) -> int:\n    return p.x + p.y + #{n}\n\n"
    lib_b << "public function scale_#{n}(v: int) -> int:\n    return v * #{n}\n\n"
  end
  File.write(File.join(workspace, "lib_a.mt"), lib_a)
  File.write(File.join(workspace, "lib_b.mt"), lib_b)

  # 220 call sites against 120 helpers: reuse a declared index rather than
  # emitting calls to helpers 120..219, which do not exist.  A fixture with 100
  # unknown-imported-member diagnostics makes the soak measure diagnostic
  # emission instead of steady-state serving, and it inflated the recorded
  # slope 4x until the session-160 check started reporting them.
  main = +"import lib_a\nimport lib_b\n\n"
  220.times do |n|
    helper = n % 120
    main << "function use_#{n}(p: lib_a.Point, v: int) -> int:\n"
    main << "    let a = lib_a.helper_#{helper}(p)\n"
    main << "    let b = lib_b.scale_#{helper}(v)\n"
    main << "    return a + b\n\n"
  end
  main << "function main() -> int:\n"
  main << "    let p = lib_a.Point(x = 1, y = 2)\n"
  main << "    return use_0(p, lib_b.SCALE)\n"
  File.write(main_path, main)
end

generate_workspace(workspace)
full = File.join(workspace, file)
base = File.read(full)

stdin_read, stdin_write = IO.pipe
stdout_read, stdout_write = IO.pipe
err_path = File.join(ROOT, "tmp", "lsp-soak-#{label || 'run'}.err")
err_file = File.open(err_path, "w")
pid = spawn(bin, "lsp", in: stdin_read, out: stdout_write, err: err_file, pgroup: true)
[stdin_read, stdout_write].each(&:close)

def write_msg(io, msg)
  body = JSON.dump(msg)
  io.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  io.flush
end

def read_msg(io)
  headers = {}
  loop do
    line = io.gets
    return nil if line.nil?
    stripped = line.chomp.sub(/\r\z/, "")
    break if stripped.empty?
    k, v = stripped.split(":", 2)
    headers[k.strip] = v.strip
  end
  JSON.parse(io.read(headers["Content-Length"].to_i))
end

def read_until(io, id)
  loop do
    m = read_msg(io)
    return { "closed" => true } if m.nil?
    next if m["method"]
    return m if m["id"] == id
  end
end

$id = 0
def request(io_w, io_r, method, params)
  $id += 1
  write_msg(io_w, { "jsonrpc" => "2.0", "id" => $id, "method" => method, "params" => params })
  Timeout.timeout(180) { read_until(io_r, $id) }
end

def rss_kb(pid)
  status = File.read("/proc/#{pid}/status")
  rss = status[/VmRSS:\s+(\d+)/, 1]
  peak = status[/VmHWM:\s+(\d+)/, 1]
  [rss&.to_i || 0, peak&.to_i || 0]
end

## Least-squares RSS slope (KB/cycle) over the samples after the first
## (warm-up) one — a slope that excludes the one-time startup cost.
def least_squares_slope(samples)
  points = samples.drop(1)
  return 0.0 if points.length < 2
  count = points.length.to_f
  mean_x = points.sum { |s| s[0] } / count
  mean_y = points.sum { |s| s[1] } / count
  num = points.sum { |s| (s[0] - mean_x) * (s[1] - mean_y) }
  den = points.sum { |s| (s[0] - mean_x)**2 }
  den.zero? ? 0.0 : num / den
end

uri = path_to_uri(full)
request(stdin_write, stdout_read, "initialize",
        { "processId" => Process.pid, "rootUri" => path_to_uri(workspace), "capabilities" => {} })
write_msg(stdin_write, { "jsonrpc" => "2.0", "method" => "initialized", "params" => {} })
write_msg(stdin_write, { "jsonrpc" => "2.0", "method" => "textDocument/didOpen",
                         "params" => { "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1,
                                                           "text" => base } } })

samples = []
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
cycles.times do |n|
  # `steady` sends the same requests against unchanged content: with correct
  # ownership every mode must read a ~0 slope, so this isolates request-path
  # leaks from the per-edit parse/analysis path.
  unless mode == "steady"
    text = n.even? ? base + "\n# soak\n" : base
    write_msg(stdin_write, { "jsonrpc" => "2.0", "method" => "textDocument/didChange",
                             "params" => { "textDocument" => { "uri" => uri, "version" => n + 2 },
                                           "contentChanges" => [{ "text" => text }] } })
  end
  if mode == "steady" || mode == "full" || mode == "tokens"
    request(stdin_write, stdout_read, "textDocument/semanticTokens/full", { "textDocument" => { "uri" => uri } })
  end
  if mode == "steady" || mode == "full" || mode == "diag"
    request(stdin_write, stdout_read, "textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
  end
  if mode == "steady" || mode == "full" || mode == "refs"
    request(stdin_write, stdout_read, "textDocument/references",
            { "textDocument" => { "uri" => uri }, "position" => { "line" => 3, "character" => 10 },
              "context" => { "includeDeclaration" => true } })
  end
  if mode == "steady" || (mode == "full" && (n % 10).zero?)
    request(stdin_write, stdout_read, "textDocument/hover",
            { "textDocument" => { "uri" => uri }, "position" => { "line" => 3, "character" => 10 } })
  end
  if (n % 50).zero?
    rss, peak = rss_kb(pid)
    samples << [n, rss, peak]
    warn "cycle #{n}: rss=#{rss}KB peak=#{peak}KB" unless quiet
  end
end

rss, peak = rss_kb(pid)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
samples << [cycles, rss, peak] unless samples.last && samples.last[0] == cycles

begin
  stdin_write.close
  Process.kill("TERM", -Process.getpgid(pid))
  Process.waitpid(pid)
rescue StandardError
  nil
end
err_file.close

baseline = samples.empty? ? rss : samples.first[1]
slope = cycles.positive? ? (rss - baseline).to_f / cycles : 0.0
ls_slope = least_squares_slope(samples)
puts "label=#{label || bin} mode=#{mode} cycles=#{cycles} elapsed=#{elapsed.round(1)}s " \
     "final_rss=#{rss}KB peak_rss=#{peak}KB slope=#{format('%.1f', slope)}KB/cycle " \
     "slope_ls=#{format('%.1f', ls_slope)}KB/cycle"
samples.each { |n, r, p| puts "  cycle #{n}: rss=#{r}KB peak=#{p}KB" } unless quiet
