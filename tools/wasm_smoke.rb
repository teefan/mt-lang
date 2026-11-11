#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end smoke for `mtc run --platform wasm`: build a package, start each
# compiler's preview server, fetch the entry + its emcc sidecars, check the
# static-file/MIME/error surface, then SIGTERM and require exit 0.
#
#   ruby tools/wasm_smoke.rb [--self PATH] [--keep] [--verbose]
#
# Skips (exit 0) when emcc is unavailable.

require "fileutils"
require "net/http"
require "open3"
require "tmpdir"
require "timeout"
require "uri"

ROOT = File.expand_path("..", __dir__)
SELF = File.expand_path(ENV.fetch("SELF", File.join(ROOT, "build/stage2/mtc")), ROOT)
HOST_CMD = ["ruby", "-I#{File.join(ROOT, "lib")}", File.join(ROOT, "bin/mtc")]

class SmokeFailure < StandardError; end

def verbose?
  ARGV.include?("--verbose")
end

def keep?
  ARGV.include?("--keep")
end

def self_path
  index = ARGV.index("--self")
  index ? File.expand_path(ARGV[index + 1], ROOT) : SELF
end

def log(message)
  puts message if verbose?
end

def emcc_available?
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
    candidate = File.join(dir, "emcc")
    File.file?(candidate) && File.executable?(candidate)
  end
end

def write_fixture(dir, name)
  FileUtils.mkdir_p(File.join(dir, "src"))
  FileUtils.mkdir_p(File.join(dir, "assets"))
  File.write(File.join(dir, "package.toml"), <<~TOML)
    [package]
    name = "#{name}"
    version = "0.1.0"
    source_root = "src"

    [build]
    entry = "src/main.mt"
    assets = ["assets"]
  TOML
  File.write(File.join(dir, "src/main.mt"), <<~MT)
    import std.stdio as stdio

    function main() -> int:
        stdio.print_line("5")
        return 0
  MT
  File.write(File.join(dir, "assets/hello.txt"), "hello\n")
end

# Start one server; return [pid, wait_thr, stdout_reader, stderr_reader, url].
def start_preview(command, dir)
  env = { "BROWSER" => "true" }
  stdin, stdout, stderr, wait_thr = Open3.popen3(env, *command, chdir: dir)
  stdin.close

  out = +""
  err = +""
  out_queue = Queue.new
  out_thread = Thread.new do
    stdout.each_line do |line|
      out << line
      out_queue << line
    end
  rescue IOError
  end
  err_thread = Thread.new do
    stderr.each_line { |line| err << line }
  rescue IOError
  end

  url = nil
  Timeout.timeout(90) do
    loop do
      line = out_queue.pop
      if (match = line.match(%r{serving (http://127\.0\.0\.1:\d+/\S+) \(press Ctrl-C to stop\)}))
        url = match[1]
        break
      end
      raise SmokeFailure, "server exited before its banner:\n#{err}" if !wait_thr.alive? && out_queue.empty?
    end
  end

  [wait_thr.pid, wait_thr, out, err, out_thread, err_thread, url]
end

def fetch(uri, method: Net::HTTP::Get)
  Net::HTTP.start(uri.host, uri.port, read_timeout: 10, open_timeout: 10) do |http|
    http.request(method.new(uri))
  end
end

def check(condition, message)
  raise SmokeFailure, message unless condition
end

def normalize_stdout(text)
  text.gsub(%r{http://127\.0\.0\.1:\d+/}, "<URL>/")
end

def exercise(command, dir, label)
  pid, wait_thr, out, err, out_thread, err_thread, url = start_preview(command, dir)
  log("#{label}: #{url}")

  entry = URI(url)
  response = fetch(entry)
  check(response.code == "200", "#{label}: entry status #{response.code}")
  check(response["content-type"] == "text/html; charset=utf-8", "#{label}: entry content-type #{response["content-type"].inspect}")
  check(response.body.include?('id="canvas"'), "#{label}: entry is missing the canvas")
  check(response.body.include?('id="output"'), "#{label}: entry is missing the output pane")
  check(response.body.include?("var Module"), "#{label}: entry is missing the bootstrap")
  check(response["cross-origin-opener-policy"] == "same-origin", "#{label}: missing COOP")
  check(response["cross-origin-embedder-policy"] == "require-corp", "#{label}: missing COEP")
  check(response["cache-control"] == "no-cache", "#{label}: missing no-cache")

  head = fetch(entry, method: Net::HTTP::Head)
  check(head.code == "200", "#{label}: HEAD status #{head.code}")
  check(head.body.nil? || head.body.empty?, "#{label}: HEAD returned a body")
  check(head["content-length"] == response["content-length"], "#{label}: HEAD length mismatch")

  js = fetch(URI(url.sub(/\.html\z/, ".js")))
  check(js.code == "200", "#{label}: js status #{js.code}")
  check(js["content-type"] == "text/javascript; charset=utf-8", "#{label}: js content-type #{js["content-type"].inspect}")
  check(js.body.bytesize.positive?, "#{label}: empty js")

  wasm = fetch(URI(url.sub(/\.html\z/, ".wasm")))
  check(wasm.code == "200", "#{label}: wasm status #{wasm.code}")
  check(wasm["content-type"] == "application/wasm", "#{label}: wasm content-type #{wasm["content-type"].inspect}")
  check(wasm.body.bytesize.positive?, "#{label}: empty wasm")

  missing = fetch(URI(url.sub(%r{/[^/]+\z}, "/nope.js")))
  check(missing.code == "404", "#{label}: missing status #{missing.code}")
  check(missing["content-type"] == "text/plain; charset=utf-8", "#{label}: missing content-type #{missing["content-type"].inspect}")

  post = fetch(entry, method: Net::HTTP::Post)
  check(post.code == "405", "#{label}: POST status #{post.code}")

  Process.kill("TERM", pid)
  status = Timeout.timeout(15) { wait_thr.value }
  out_thread.join(1)
  err_thread.join(1)
  check(status.exitstatus == 0, "#{label}: server exit #{status.exitstatus.inspect}, stderr=#{err.inspect}")
  normalized = normalize_stdout(out)
  check(normalized == "serving <URL>/#{File.basename(URI(url).path)} (press Ctrl-C to stop)\n",
        "#{label}: unexpected stdout #{normalized.inspect}")
  check(err.empty?, "#{label}: unexpected stderr #{err.inspect}")
  log("#{label}: ok")
rescue StandardError
  begin
    Process.kill("KILL", pid) if pid && wait_thr&.alive?
  rescue StandardError
    nil
  end
  raise
end

unless emcc_available?
  puts "wasm smoke: skipped (emcc not found)"
  exit 0
end

self_bin = self_path
check(File.file?(self_bin) && File.executable?(self_bin), "self compiler not found: #{self_bin}")

root = Dir.mktmpdir("wasm-smoke")
begin
  host_dir = File.join(root, "host")
  self_dir = File.join(root, "self")
  write_fixture(host_dir, "smokehost")
  write_fixture(self_dir, "smokeself")

  exercise(HOST_CMD + ["run", ".", "-I", ROOT, "--platform", "wasm", "--no-cache"], host_dir, "host")
  exercise([self_bin, "run", ".", "-I", ROOT, "--platform", "wasm", "--no-cache"], self_dir, "self")
  puts "wasm smoke: host=ok self=ok"
ensure
  if keep?
    puts "kept fixture: #{root}"
  else
    FileUtils.rm_rf(root)
  end
end
