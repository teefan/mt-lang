#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sexpr_parity — compare the self-host compiler's `lex|parse|lower --sexpr`
# output against the Ruby host compiler, byte for byte.
#
# The Ruby host is slow to start (~0.5s per process: startup + require), which
# dominates `lex`/`parse` and is a large fixed cost for `lower`.  So this tool
# loads `milk_tea` once in the parent, then forks workers that invoke the CLI
# in-process for a slice of the file list.  The self-host compiler is a native
# binary, so it is run once per file (startup is negligible) in parallel.
#
# Usage:
#   tools/sexpr_parity.rb [MODE] [TARGET...] [options]
#
#   MODE      lex | parse | lower | all        (default: all)
#   TARGET    files or directories             (default: repository root)
#
# Options:
#   --self PATH      self-host compiler binary  (default: build/stage2/mtc)
#   -j, --jobs N     parallel workers           (default: nproc; 4 for lower)
#   -I, --include D  extra module root for `lower` (repeatable)
#   --timeout SEC    per self-host invocation timeout (default: 120)
#   --mem-mb MB      virtual-memory cap for the self-host binary (0 = off)
#   --host-cache DIR reuse the host's outputs cached under DIR (see the
#                    "host-output cache" section below); the self side always
#                    runs live
#   --max-diffs N    differing files to detail  (default: 20)
#   --keep           keep generated outputs and print their directory
#   -q, --quiet      print only the summary
#   -h, --help       show this message
#
# Exit status: 0 when every comparable file matches, 1 otherwise.

require "digest"
require "etc"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require "stringio"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

MODES = %w[lex parse lower].freeze
EXCLUDE_DIRS = %w[.git .opencode build node_modules third_party tmp].freeze

def usage
  File.read(__FILE__).lines.drop(2).take_while { |l| l.start_with?("#") }
      .map { |l| l.sub(/\A# ?/, "") }.join
end

# ── options ──────────────────────────────────────────────────────────────────

mode = nil
targets = []
self_bin = nil
jobs = Etc.nprocessors
jobs_explicit = false
includes = []
timeout_s = 120
mem_mb = 0
host_cache_dir = nil
max_diffs = 20
keep = false
quiet = false

argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when "--self"     then self_bin = argv.shift
  when "-j", "--jobs" then jobs = argv.shift.to_i; jobs_explicit = true
  when "-I", "--include" then includes << argv.shift
  when "--timeout"  then timeout_s = argv.shift.to_i
  when "--mem-mb"   then mem_mb = argv.shift.to_i
  when "--host-cache" then host_cache_dir = argv.shift
  when "--max-diffs" then max_diffs = argv.shift.to_i
  when "--keep"     then keep = true
  when "-q", "--quiet" then quiet = true
  when "-h", "--help" then puts usage; exit 0
  else
    if mode.nil? && MODES.include?(a)
      mode = a
    else
      targets << a
    end
  end
end

mode ||= "all"
jobs = 1 if jobs < 1
modes = mode == "all" ? MODES : [mode]

# A lower sweep runs one self compiler per worker; a compiler-sized closure
# peaks at ~3.8 GiB (the documented `main*` loop-guard artifacts), so the
# nproc-wide default has exhausted a 31 GiB workstation.  Keep the default
# bounded; an explicit -j still wins.  --mem-mb caps a runaway process.
if mode == "lower" && !jobs_explicit
  jobs = 4 if jobs > 4
end
if modes.include?("lower") && mem_mb.zero?
  warn "note: lower runs are memory-heavy (a compiler-sized closure peaks ~3.8 GiB); pass --mem-mb 8000 and keep -j at 4."
end

self_bin ||= File.join(ROOT, "build", "stage2", "mtc")
self_bin = File.expand_path(self_bin)
unless File.executable?(self_bin)
  warn "error: self-host compiler not found or not executable: #{self_bin}"
  warn "       build one with: ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o #{self_bin}"
  exit 1
end

newest_src = Dir.glob(File.join(ROOT, "projects", "mtc", "src", "**", "*.mt"))
                .map { |f| File.mtime(f) }.max
if newest_src && File.mtime(self_bin) < newest_src
  warn "warning: #{self_bin} is older than the newest self-host source — rebuild it for accurate parity."
end

# ── file list ────────────────────────────────────────────────────────────────

def excluded?(path)
  parts = path.split(File::SEPARATOR)
  return true if parts.any? { |p| EXCLUDE_DIRS.include?(p) }
  path.include?("/bindings/vscode/")
end

def expand_targets(targets)
  files = []
  targets.each do |t|
    if File.directory?(t)
      Dir.glob(File.join(t, "**", "*.mt")).each { |f| files << f unless excluded?(f) }
    elsif File.exist?(t)
      files << t
    else
      warn "warning: target does not exist: #{t}"
    end
  end
  files.map { |f| f.sub(%r{\A\./}, "") }.uniq.sort
end

targets = [ROOT] if targets.empty?
files = expand_targets(targets)
if files.empty?
  warn "error: no .mt files found"
  exit 1
end

require "milk_tea"

# ── host-output cache ────────────────────────────────────────────────────────
#
# The host is deterministic but expensive (a Ruby process per lex/parse file, a
# whole compile per lower), so --host-cache DIR reuses its outputs:
#
#   lex/parse  the key is the file's digest plus its inferred module name; the
#              dump is a pure per-file read.
#   lower      the key also folds in the digests of every module the host's own
#              resolution reads for this file — the explicit imports
#              transitively, plus the modules the loader's installers add
#              (std.option/std.result, std.async for an `async fn main`).  The
#              recorded import *names* are re-resolved through the host's own
#              ModulePathResolver on every run (resolution only stats files),
#              so a module appearing at an earlier root still wins and a moved
#              resolution misses.
#
# The self side always runs live — it is the thing under test.  A file whose
# closure does not resolve/read, and any nonzero host exit, is never cached:
# a stale entry must not answer where the host would do something else.  A
# change to the host's own sources (lib/**, bin/mtc) wipes the cache.  The
# full-corpus cache is large (~1.5 GB — the lower dumps dominate) but lives
# under a disposable tmp/ path.
class HostOutputCache
  # Bump when the key scheme changes, so entries from an older scheme cannot
  # be read under a coincidentally equal key.
  CACHE_FORMAT = "1"

  def initialize(dir)
    @dir = File.expand_path(dir)
    @entries = File.join(@dir, "entries")
    FileUtils.mkdir_p(@entries)
    revision = "#{CACHE_FORMAT}:#{self.class.host_revision}"
    stamp = File.join(@dir, "host-rev")
    if File.exist?(stamp) && File.read(stamp).strip == revision
      @graph = load_graph
    else
      FileUtils.rm_rf(@entries)
      FileUtils.mkdir_p(@entries)
      File.write(stamp, revision)
      @graph = {}
    end
    @digests = {}
    @hits = 0
    @misses = 0
    @uncacheable = 0
    @stored = 0
    @graph_dirty = false
  end

  def self.host_revision
    Dir.glob([File.join(ROOT, "lib/**/*.rb"), File.join(ROOT, "bin/mtc")])
       .map { |f| File.mtime(f).to_i }.max.to_s
  end

  def load_graph
    raw = JSON.parse(File.read(File.join(@dir, "graph.json")))
    raw.is_a?(Hash) ? raw : {}
  rescue StandardError
    {}
  end

  def save
    return unless @graph_dirty

    path = File.join(@dir, "graph.json")
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.generate(@graph))
    File.rename(tmp, path)
  end

  def report
    "host-cache #{@dir}: #{@hits} hits / #{@misses} misses / " \
      "#{@uncacheable} uncacheable / #{@stored} stored"
  end

  # The cache key for one (mode, file): nil when the file cannot be cached
  # (unreadable, or a lower closure that does not resolve).
  def key_for(mode, file, includes)
    effective = effective_source_path(file) or return nil
    digest = digest_of(effective) or return nil
    roots = host_roots(file, includes) or return nil
    module_name = inferred_module_name(effective, roots) or return nil
    if mode == "lower"
      closure = closure_entries(effective, roots) or return nil
      material = ["lower", relative_path(File.expand_path(file)), digest, module_name,
                  roots.join("\0"), includes.join("\0"),
                  closure.map { |path, hash| "#{path}\0#{hash}" }.join("\0")]
    else
      material = [mode, relative_path(File.expand_path(file)), digest, module_name]
    end
    Digest::SHA256.hexdigest(material.join("\0"))
  rescue StandardError
    nil
  end

  # Copy a cached host result into the run's host dir; false on a miss.
  def prefill(key, host_dir, idx)
    return false unless key

    base = File.join(@entries, key)
    return false unless File.exist?("#{base}.out")

    File.binwrite(File.join(host_dir, "#{idx}.out"), File.binread("#{base}.out"))
    File.binwrite(File.join(host_dir, "#{idx}.err"), File.binread("#{base}.err"))
    File.write(File.join(host_dir, "#{idx}.rc"), File.read("#{base}.rc"))
    @hits += 1
    true
  end

  def miss(key)
    if key
      @misses += 1
    else
      @uncacheable += 1
    end
  end

  # Cache one successful host run (rc == 0) from the run's host dir.
  def store(key, host_dir, idx)
    base = File.join(@entries, key)
    FileUtils.cp(File.join(host_dir, "#{idx}.out"), "#{base}.out")
    FileUtils.cp(File.join(host_dir, "#{idx}.err"), "#{base}.err")
    FileUtils.cp(File.join(host_dir, "#{idx}.rc"), "#{base}.rc")
    @stored += 1
  end

  private

  def digest_of(path)
    expanded = File.expand_path(path)
    @digests[expanded] ||= Digest::SHA256.file(expanded).hexdigest
  rescue StandardError
    nil
  end

  # The file the host actually reads: a platform variant wins over the base
  # name (`foo.mt` → `foo.linux.mt` when it exists), exactly as the CLI's
  # `resolve_source_path` does for the requested path.
  def effective_source_path(file)
    MilkTea::ModuleLoader.resolve_source_path(
      File.expand_path(file), platform: MilkTea::ModuleLoader.default_host_platform
    )
  rescue StandardError
    nil
  end

  def relative_path(path)
    prefix = "#{ROOT}/"
    path.start_with?(prefix) ? path.delete_prefix(prefix) : path
  end

  def inferred_module_name(path, roots)
    MilkTea::ModuleLoader.new(module_roots: roots).inferred_module_name_for_path(path)
  rescue StandardError
    nil
  end

  # The host CLI's `module_roots_for`: -I roots first, then the path's own.
  def host_roots(file, includes)
    roots = includes.dup
    MilkTea::ModuleRoots.roots_for_path(file).each do |root|
      roots << root unless roots.include?(root)
    end
    roots.map { |root| File.expand_path(root.to_s) }.uniq
  rescue StandardError
    nil
  end

  # Every module the host's resolution reads for `file` under `roots`, as
  # [relative path, digest] pairs (the file itself included), or nil when one
  # of them cannot be read or resolved.
  def closure_entries(file, roots)
    resolver = MilkTea::ModulePathResolver.new(
      module_roots: roots, platform: MilkTea::ModuleLoader.default_host_platform,
      package_graph: nil, source_overrides: nil, package_manifest_cache: {}
    )
    seen = {}
    out = []
    stack = [File.expand_path(file)]
    until stack.empty?
      path = stack.pop
      next if seen[path]

      seen[path] = true
      digest = digest_of(path) or return nil
      out << [relative_path(path), digest]
      deps = deps_for(path, resolver) or return nil
      deps.each { |dep| stack << dep }
    end
    out.sort
  end

  # The host's resolved inputs for one module: its explicit imports plus the
  # loader installers' implicit modules.  The parse facts are kept in the graph
  # keyed by digest; the resolution itself re-runs every time, so a module that
  # appeared at an earlier root since the last run still wins.
  def deps_for(path, resolver)
    digest = digest_of(path) or return nil
    entry = @graph[path]
    if entry.nil? || entry["digest"] != digest
      entry = parse_entry(path, digest) or return nil
      @graph[path] = entry
      @graph_dirty = true
    end
    deps = []
    entry["imports"].each do |name|
      dep = resolve_path(resolver, name, importer_path: path, importer_module_name: entry["module_name"])
      return nil unless dep

      deps << dep
    end
    entry["implicit"].each do |name|
      dep = resolve_path(resolver, name, importer_path: path)
      return nil unless dep

      deps << dep
    end
    deps
  end

  def parse_entry(path, digest)
    ast = MilkTea::ModuleLoader.load_file(path)
    {
      "digest" => digest,
      "imports" => ast.imports.map { |import| import.path.to_s },
      "implicit" => implicit_module_names(ast),
      "module_name" => ast.module_name.to_s,
    }
  rescue StandardError
    nil
  end

  def resolve_path(resolver, name, importer_path:, importer_module_name: nil)
    resolved = resolver.resolve_module_path(name, importer_path: importer_path,
                                                  importer_module_name: importer_module_name)
    File.expand_path(resolved)
  rescue StandardError
    nil
  end

  # What the loader's installers add on top of the explicit imports, asked of
  # the host's own objects so the rule cannot drift.
  def implicit_module_names(ast)
    names = []
    module_name = ast.module_name.to_s
    unless MilkTea::PreludeInstaller::PRELUDE_MODULE_PATHS.include?(module_name)
      names.concat(MilkTea::PreludeInstaller::PRELUDE_MODULE_PATHS)
    end
    recorder = MilkTea::AsyncRuntimeInstaller.new(
      resolve_module_path: lambda { |name, importer_path: nil|
        names << name
        nil
      },
      check_block: ->(*) {}, bind_block: ->(*) {}
    )
    recorder.install_async_runtime_dependency!(ast, {})
    names
  end
end

cache = host_cache_dir ? HostOutputCache.new(host_cache_dir) : nil

unless quiet
  puts "host: ruby #{RUBY_VERSION} (milk_tea #{MilkTea::VERSION})"
  puts "self: #{self_bin} (built #{File.mtime(self_bin).strftime('%Y-%m-%d %H:%M')})"
end

# ── host / self invocation ───────────────────────────────────────────────────

def run_host(mode, file, includes)
  cmd = [mode, file]
  includes.each { |d| cmd += ["-I", d] } if mode == "lower"
  cmd << "--sexpr"
  out = StringIO.new
  err = StringIO.new
  rc = MilkTea::CLI.start(cmd, out: out, err: err)
  [out.string, err.string, rc]
end

def run_self(bin, mode, file, includes, timeout_s, mem_mb)
  cmd = [mode, file]
  if mode == "lower"
    roots = (MilkTea::ModuleRoots.roots_for_path(file) + includes).uniq
    roots.each { |d| cmd += ["-I", d] }
  end
  cmd << "--sexpr"

  full = [bin, *cmd]
  if mem_mb.positive?
    inner = full.map { |a| Shellwords.escape(a) }.join(" ")
    full = ["bash", "-c", "ulimit -v #{mem_mb * 1024}; exec #{inner}"]
  end
  full = ["timeout", timeout_s.to_s, *full]

  out, err, status = Open3.capture3(*full)
  [out, err, status.exitstatus]
end

# ── worker ───────────────────────────────────────────────────────────────────

def run_workers(mode, jobs, files, host_dir, self_dir, self_bin, includes, timeout_s, mem_mb, prefilled)
  jobs = files.length if jobs > files.length
  pids = (0...jobs).map do |worker|
    fork do
      idx = worker
      while idx < files.length
        file = files[idx]
        begin
          unless prefilled[idx]
            out, herr, rc = run_host(mode, file, includes)
            File.binwrite(File.join(host_dir, "#{idx}.out"), out)
            File.write(File.join(host_dir, "#{idx}.err"), herr)
            File.write(File.join(host_dir, "#{idx}.rc"), rc.to_s)
          end

          sout, serr, src = run_self(self_bin, mode, file, includes, timeout_s, mem_mb)
          File.binwrite(File.join(self_dir, "#{idx}.out"), sout)
          File.write(File.join(self_dir, "#{idx}.err"), serr)
          File.write(File.join(self_dir, "#{idx}.rc"), src.to_s)
        rescue => e
          File.write(File.join(host_dir, "#{idx}.rc"), "1")
          File.write(File.join(self_dir, "#{idx}.rc"), "1")
          File.write(File.join(self_dir, "#{idx}.err"), "harness error: #{e.class}: #{e.message}")
        end
        idx += jobs
      end
      exit!(0)
    end
  end
  pids.each { |pid| Process.wait(pid) }
end

# ── comparison ───────────────────────────────────────────────────────────────

def read_int(path)
  File.exist?(path) ? File.read(path).to_i : 1
end

def first_diff(a, b)
  n = [a.bytesize, b.bytesize].min
  i = 0
  i += 1 while i < n && a.getbyte(i) == b.getbyte(i)
  i
end

def snippet(bytes, at)
  text = bytes[[at - 60, 0].max, 180] || +""
  text.encode("UTF-8", invalid: :replace, undef: :replace).gsub(/[[:space:]]+/, " ").strip
end

# ── run ──────────────────────────────────────────────────────────────────────

overall_ok = true

modes.each do |mode|
  host_dir = File.join(ROOT, "tmp", "sexpr-parity", mode, "host")
  self_dir = File.join(ROOT, "tmp", "sexpr-parity", mode, "self")
  FileUtils.rm_rf(File.dirname(host_dir))
  FileUtils.mkdir_p(host_dir)
  FileUtils.mkdir_p(self_dir)

  keys = Array.new(files.length)
  prefilled = Array.new(files.length, false)
  if cache
    files.each_with_index do |file, idx|
      keys[idx] = cache.key_for(mode, file, includes)
      prefilled[idx] = cache.prefill(keys[idx], host_dir, idx)
      cache.miss(keys[idx]) unless prefilled[idx]
    end
  end

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_workers(mode, jobs, files, host_dir, self_dir, self_bin, includes, timeout_s, mem_mb, prefilled)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

  if cache
    files.each_with_index do |_file, idx|
      key = keys[idx]
      next if key.nil? || prefilled[idx]
      next unless read_int(File.join(host_dir, "#{idx}.rc")) == 0

      cache.store(key, host_dir, idx)
    end
  end

  match = 0
  differ = []
  hostfail = []
  selffail = []

  files.each_with_index do |file, idx|
    hrc = read_int(File.join(host_dir, "#{idx}.rc"))
    src = read_int(File.join(self_dir, "#{idx}.rc"))
    if hrc != 0
      hostfail << [idx, file]
    elsif src != 0
      selffail << [idx, file]
    else
      hout = File.binread(File.join(host_dir, "#{idx}.out"))
      sout = File.binread(File.join(self_dir, "#{idx}.out"))
      if hout == sout
        match += 1
      else
        differ << [file, hout, sout]
      end
    end
  end

  # A host-side rejection is not a self-host regression; a `differ` or a
  # `selffail` (self-host failed where the host succeeded) is.
  overall_ok = false if differ.any? || selffail.any?

  puts format("mode=%-5s files=%-4d match=%-4d differ=%-3d hostfail=%-3d selffail=%-3d (%.1fs, %d jobs)",
              mode, files.length, match, differ.length, hostfail.length, selffail.length, elapsed, jobs)

  next if quiet

  differ.take(max_diffs).each do |file, hout, sout|
    at = first_diff(hout, sout)
    puts "  DIFF #{file} @byte #{at}"
    puts "    host: #{snippet(hout, at)}"
    puts "    self: #{snippet(sout, at)}"
  end
  puts "  ... #{differ.length - max_diffs} more differing file(s)" if differ.length > max_diffs

  selffail.take(max_diffs).each do |idx, file|
    err_path = File.join(self_dir, "#{idx}.err")
    out_path = File.join(self_dir, "#{idx}.out")
    detail = File.exist?(err_path) ? File.read(err_path).strip : ""
    # The self-host `parse` command writes diagnostics to stdout, so fall back
    # to it when stderr is empty.
    if detail.empty? && File.exist?(out_path)
      detail = File.binread(out_path)[0, 200].to_s
                   .encode("UTF-8", invalid: :replace, undef: :replace).strip
    end
    puts "  SELF-FAIL #{file}: #{detail.lines.first(2).join.strip}"
  end
  hostfail.take(max_diffs).each do |idx, file|
    err_path = File.join(host_dir, "#{idx}.err")
    detail = File.exist?(err_path) ? File.read(err_path).strip.lines.first.to_s.strip : ""
    puts "  HOST-FAIL #{file}: #{detail}"
  end

  FileUtils.rm_rf(File.dirname(host_dir)) unless keep
end

if cache
  cache.save
  puts cache.report
end
puts "kept outputs under tmp/sexpr-parity/" if keep
exit(overall_ok ? 0 : 1)
