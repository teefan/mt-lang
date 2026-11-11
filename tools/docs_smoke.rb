#!/usr/bin/env ruby
# frozen_string_literal: true

# Host-vs-self smoke for `mtc docs`: start each server (ephemeral port), fetch
# the reference/module/source/highlight/search/static/404 routes, compare the
# byte-stable responses, then SIGTERM and require exit 0.
#
#   ruby tools/docs_smoke.rb [--self PATH] [--verbose]

require "fileutils"
require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"

ROOT = File.expand_path("..", __dir__)
SELF = File.expand_path(ENV.fetch("SELF", File.join(ROOT, "build/stage2/mtc")), ROOT)
HOST_CMD = ["ruby", "-I#{File.join(ROOT, "lib")}", File.join(ROOT, "bin/mtc")]

class SmokeFailure < StandardError; end

def verbose?
  ARGV.include?("--verbose")
end

def self_path
  index = ARGV.index("--self")
  index ? File.expand_path(ARGV[index + 1], ROOT) : SELF
end

def log(message)
  puts message if verbose?
end

def check(condition, message)
  raise SmokeFailure, message unless condition
end

def content_type(response)
  response["content-type"].to_s.gsub(/\s+/, "").downcase
end

# Start a docs server; return [pid, wait_thr, stdout, stderr, url].
def start_server(command)
  env = { "BROWSER" => "true" }
  stdin, stdout, stderr, wait_thr = Open3.popen3(env, *command, chdir: ROOT)
  stdin.close

  out = +""
  err = +""
  queue = Queue.new
  out_thread = Thread.new do
    stdout.each_line { |line| out << line; queue << line }
  rescue IOError
  end
  err_thread = Thread.new do
    stderr.each_line { |line| err << line }
  rescue IOError
  end

  url = nil
  Timeout.timeout(60) do
    loop do
      line = queue.pop
      if (match = line.match(%r{Serving Milk Tea docs at (http://127\.0\.0\.1:\d+/)}))
        url = match[1]
        break
      end
      raise SmokeFailure, "docs server exited before its banner:\n#{err}" if !wait_thr.alive? && queue.empty?
    end
  end

  [wait_thr.pid, wait_thr, out, err, out_thread, err_thread, url]
end

def get(url)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, read_timeout: 30, open_timeout: 10) do |http|
    http.request(Net::HTTP::Get.new(uri))
  end
end

def stop(pid, wait_thr, out_thread, err_thread)
  # Ctrl+C (SIGINT) is the host's documented shutdown path; Puma turns TERM
  # into a signal termination with no exit status.
  Process.kill("INT", pid)
  status = Timeout.timeout(15) { wait_thr.value }
  out_thread.join(1)
  err_thread.join(1)
  status
end

def exercise(command, label)
  pid, wait_thr, out, err, out_thread, err_thread, base = start_server(command)
  log("#{label}: #{base}")

  root = get(base)
  check(root.code == "200", "#{label}: / status #{root.code}")
  check(content_type(root).start_with?("text/html"), "#{label}: / content-type #{root["content-type"].inspect}")
  check(root.body.include?("Milk Tea"), "#{label}: / is not the reference index")

  reference = get("#{base}reference/")
  check(reference.code == "200" && reference.body == root.body, "#{label}: /reference/ mismatch")

  redirect = get("#{base}reference")
  check(redirect.code == "302", "#{label}: /reference status #{redirect.code}")
  check(redirect["location"].to_s.end_with?("/reference/"), "#{label}: /reference location #{redirect["location"].inspect}")

  stdlib = get("#{base}stdlib")
  check(stdlib.code == "200", "#{label}: /stdlib status #{stdlib.code}")
  %w[vec string map].each do |name|
    check(stdlib.body.include?(name), "#{label}: /stdlib is missing #{name}")
  end

  module_page = get("#{base}stdlib/vec")
  check(module_page.code == "200", "#{label}: /stdlib/vec status #{module_page.code}")
  check(module_page.body.include?("Vec"), "#{label}: /stdlib/vec is missing Vec")

  source = get("#{base}stdlib/vec/source/vec")
  check(source.code == "200", "#{label}: source status #{source.code}")
  check(content_type(source).start_with?("text/plain"), "#{label}: source content-type #{source["content-type"].inspect}")
  check(source.body.include?("public struct Vec"), "#{label}: source body mismatch")

  highlight = get("#{base}stdlib/vec/source/vec/hl")
  check(["200", "503"].include?(highlight.code), "#{label}: highlight status #{highlight.code}")
  if highlight.code == "200"
    check(content_type(highlight).start_with?("text/html"), "#{label}: highlight content-type #{highlight["content-type"].inspect}")
    check(highlight.body.include?("Milk Tea Snapshot"), "#{label}: highlight body mismatch")
  end

  search = get("#{base}api/search?q=ve")
  check(search.code == "200", "#{label}: search status #{search.code}")
  check(content_type(search).start_with?("application/json"), "#{label}: search content-type #{search["content-type"].inspect}")
  entries = JSON.parse(search.body)
  entry = entries.find { |item| item["name"] == "vec" }
  check(entry, "#{label}: search is missing vec")
  check(entry["kind"] == "file", "#{label}: search vec kind #{entry["kind"].inspect}")

  css = get("#{base}css/docs.css")
  check(css.code == "200" && content_type(css).start_with?("text/css"), "#{label}: css route")
  js = get("#{base}js/docs.js")
  check(js.code == "200" && content_type(js).start_with?("text/javascript"), "#{label}: js route")

  missing = get("#{base}nope")
  check(missing.code == "404", "#{label}: missing status #{missing.code}")

  status = stop(pid, wait_thr, out_thread, err_thread)
  check(status.exitstatus == 0, "#{label}: exit #{status.exitstatus.inspect}, stderr=#{err.inspect}")
  normalized = out.gsub(%r{http://127\.0\.0\.1:\d+/}, "<URL>/")
  # Sinatra/Puma appends its own startup/shutdown log lines to stdout; the
  # CLI's banner is the stable prefix.
  check(normalized.start_with?("Serving Milk Tea docs at <URL>/\nPress Ctrl+C to stop.\n"),
        "#{label}: unexpected stdout #{normalized.inspect}")

  { root: root.body, reference: reference.body, source: source.body, css: css.body, js: js.body,
    highlight: highlight.code == "200" ? highlight.body : nil }
rescue StandardError
  begin
    Process.kill("KILL", pid) if pid && wait_thr&.alive?
  rescue StandardError
    nil
  end
  raise
end

self_bin = self_path
check(File.file?(self_bin) && File.executable?(self_bin), "self compiler not found: #{self_bin}")

host = exercise(HOST_CMD + ["docs"], "host")
self_result = exercise([self_bin, "docs"], "self")

%i[root reference source css js].each do |key|
  check(host[key] == self_result[key], "host/self #{key} bytes differ")
end
if host[:highlight] && self_result[:highlight]
  check(host[:highlight] == self_result[:highlight], "host/self highlight bytes differ")
end

puts "docs smoke: host=ok self=ok"
