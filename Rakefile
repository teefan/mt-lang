require 'fileutils'
require 'open3'
require 'rake/testtask'
require_relative 'lib/milk_tea'
require_relative 'lib/milk_tea/bindings'

RAW_BINDINGS = MilkTea::RawBindings.default_registry(root: MilkTea.root)
IMPORTED_BINDINGS = MilkTea::ImportedBindings.default_registry(root: MilkTea.root)
ALL_TEST_PATTERN = '{test/compiler,test/tooling,test/std,test/bindings,test/packages}/**/*_test.rb'
COVERAGE_DIR = File.expand_path('coverage/minitest', __dir__)
COVERAGE_BASELINE_PATH = File.join(COVERAGE_DIR, 'baseline.json')
COVERAGE_TESTS_PATH = File.join(COVERAGE_DIR, 'tests.json')
COVERAGE_REPORT_PATH = File.join(COVERAGE_DIR, 'report.txt')
RAW_COVERAGE_DIR = File.expand_path('coverage/raw', __dir__)
RAW_COVERAGE_JSON_PATH = File.join(RAW_COVERAGE_DIR, 'coverage.json')
RAW_COVERAGE_SUMMARY_PATH = File.join(RAW_COVERAGE_DIR, 'summary.txt')
GENERATED_FIXTURE_FILE = File.expand_path('test/fixtures/language_fixture.mt', __dir__)
GENERATED_FIXTURE_DIR = File.expand_path('test/fixtures/language_fixture', __dir__)
GENERATED_FIXTURE_ROOT = File.expand_path('test/fixtures', __dir__)

task default: :test
task verify: [:test, *RAW_BINDINGS.check_task_names, *IMPORTED_BINDINGS.check_task_names]

desc 'Run all tests'
Rake::TestTask.new do |t|
  t.libs << '.'
  t.libs << 'test'
  t.loader = :direct
  t.test_files = FileList[ALL_TEST_PATTERN].sort.map { |path| File.expand_path(path) }
end

namespace :test do
  {
    compiler: 'test/compiler/**/*_test.rb',
    tooling: 'test/tooling/**/*_test.rb',
    std: 'test/std/**/*_test.rb',
    packages: 'test/packages/**/*_test.rb',
  }.each do |name, pattern|
    desc "Run #{name} tests"
    Rake::TestTask.new(name) do |t|
      t.libs << 'test'
      t.pattern = pattern
    end
  end
end

namespace :coverage do
  def coverage_test_files
    Rake::FileList[ALL_TEST_PATTERN].sort
  end

  def cleanup_generated_fixture_artifacts
    FileUtils.rm_f(GENERATED_FIXTURE_FILE)
    FileUtils.rm_rf(GENERATED_FIXTURE_DIR)
    Dir.rmdir(GENERATED_FIXTURE_ROOT) if Dir.exist?(GENERATED_FIXTURE_ROOT) && Dir.empty?(GENERATED_FIXTURE_ROOT)
  end

  def move_coverage_output(destination)
    source = File.expand_path('coverage.json', __dir__)
    raise 'minitest-coverage did not write coverage.json' unless File.file?(source)

    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.rm_f(destination)
    FileUtils.mv(source, destination)
  end

  desc 'Generate the minitest-coverage baseline for the current implementation'
  task :baseline do
    FileUtils.mkdir_p(COVERAGE_DIR)
    FileUtils.rm_f(File.expand_path('coverage.json', __dir__))
    cleanup_generated_fixture_artifacts
    sh 'bundle', 'exec', 'minitest_coverage_baseline'
    move_coverage_output(COVERAGE_BASELINE_PATH)
  end

  desc 'Run the full test suite under minitest-coverage'
  task full: :baseline do
    files = coverage_test_files
    raise "no tests matched #{ALL_TEST_PATTERN}" if files.empty?

    FileUtils.rm_f(File.expand_path('coverage.json', __dir__))
    begin
      sh 'bundle', 'exec', 'minitest_coverage', "--coverage=#{COVERAGE_BASELINE_PATH}", *files
      move_coverage_output(COVERAGE_TESTS_PATH)
    ensure
      cleanup_generated_fixture_artifacts
    end
  end

  desc 'Generate and save the minitest-coverage report for the full test suite'
  task report: :full do
    FileUtils.mkdir_p(COVERAGE_DIR)
    output, status = Open3.capture2e('bundle', 'exec', 'minitest_coverage_report', COVERAGE_BASELINE_PATH, COVERAGE_TESTS_PATH)
    raise 'minitest-coverage report failed' unless status.success?

    File.write(COVERAGE_REPORT_PATH, output)
    puts output
  end

  desc 'Generate a plain Ruby Coverage line report for the full test suite'
  task :raw do
    files = coverage_test_files
    raise "no tests matched #{ALL_TEST_PATTERN}" if files.empty?

    begin
      cleanup_generated_fixture_artifacts
      sh(
        {
          'MILK_TEA_RAW_COVERAGE_JSON_PATH' => RAW_COVERAGE_JSON_PATH,
          'MILK_TEA_RAW_COVERAGE_SUMMARY_PATH' => RAW_COVERAGE_SUMMARY_PATH,
        },
        'bundle', 'exec', 'ruby', 'test/raw_coverage_runner.rb', *files,
      )
    ensure
      cleanup_generated_fixture_artifacts
    end
  end

  desc 'Remove generated minitest coverage artifacts'
  task :clean do
    FileUtils.rm_rf(COVERAGE_DIR)
    FileUtils.rm_rf(RAW_COVERAGE_DIR)
    FileUtils.rm_f(File.expand_path('coverage.json', __dir__))
    cleanup_generated_fixture_artifacts
  end
end

desc 'Generate the minitest-coverage report for the full suite'
task coverage: 'coverage:report'

namespace :deps do
  desc 'Ensure vendored third_party upstream folders are present at the pinned revisions'
  task :bootstrap do
    MilkTea::UpstreamSources.bootstrap_all!.each do |result|
      verb = result.status == :present ? 'kept' : 'bootstrapped'
      puts "#{verb} #{result.source.name} -> #{result.path}"
    end
  end

  desc 'Resolve a git tag or branch to a commit hash for an upstream source'
  task :resolve, [:source, :ref] do |_t, args|
    source_name = args[:source]
    ref = args[:ref]
    unless source_name && ref
      puts "usage: rake deps:resolve[source_name,tag_or_branch]"
      puts "example: rake deps:resolve[raylib,v5.5]"
      exit 1
    end

    source = MilkTea::UpstreamSources.find_source(source_name)
    unless source
      known = MilkTea::UpstreamSources.default_sources.map(&:name).join(", ")
      puts "unknown upstream source: #{source_name}"
      puts "known sources: #{known}"
      exit 1
    end

    hash = MilkTea::UpstreamSources.resolve_ref(source.repository_url, ref)
    puts "#{source_name}: #{ref.inspect} → #{hash}"
  end

  desc 'Pin an upstream source to a new revision (tag, branch, or commit hash)'
  task :bump, [:source, :version] do |_t, args|
    source_name = args[:source]
    version = args[:version]
    unless source_name && version
      puts "usage: rake deps:bump[source_name,version]"
      puts "  version may be a tag (v6.0.0), branch, or full commit hash"
      puts "example: rake deps:bump[raylib,v6.0.0]"
      exit 1
    end

    source = MilkTea::UpstreamSources.find_source(source_name)
    unless source
      known = MilkTea::UpstreamSources.default_sources.map(&:name).join(", ")
      puts "error: unknown upstream source: #{source_name}"
      puts "known sources: #{known}"
      exit 1
    end

    hash = MilkTea::UpstreamSources.resolve_ref(source.repository_url, version)
    MilkTea::UpstreamSources.write_version_override(source_name, hash)
    puts "pinned #{source_name} to #{hash} (resolved from #{version.inspect})"
    puts "updated config/upstream_versions.yml"
  end

  desc 'Upgrade an upstream C library: bump revision, rebootstrap, regenerate all bindings'
  task :upgrade, [:source, :version] do |_t, args|
    source_name = args[:source]
    version = args[:version]
    unless source_name && version
      puts "usage: rake deps:upgrade[source_name,version]"
      puts "  version may be a tag (v6.0.0), branch, or full commit hash"
      puts "example: rake deps:upgrade[raylib,v6.0.0]"
      puts ""
      puts "this runs: bump → bootstrap → bindgen:all → imported_bindings:all → verify"
      exit 1
    end

    source = MilkTea::UpstreamSources.find_source(source_name)
    unless source
      known = MilkTea::UpstreamSources.default_sources.map(&:name).join(", ")
      puts "error: unknown upstream source: #{source_name}"
      puts "known sources: #{known}"
      exit 1
    end

    puts "=== Step 1/5: bump #{source_name} to #{version.inspect} ==="
    hash = MilkTea::UpstreamSources.resolve_ref(source.repository_url, version)
    MilkTea::UpstreamSources.write_version_override(source_name, hash)
    puts "pinned #{source_name} → #{hash}"

    puts ""
    puts "=== Step 2/5: bootstrap #{source_name} ==="
    result = MilkTea::UpstreamSources.bootstrap_one(source_name)
    puts "#{result.status == :present ? 'kept' : 'bootstrapped'} #{source_name} -> #{result.path}"

    puts ""
    puts "=== Step 3/5: regenerate raw bindings (bindgen:all) ==="
    Rake::Task["bindgen:all"].invoke

    puts ""
    puts "=== Step 4/5: regenerate imported bindings (imported_bindings:all) ==="
    Rake::Task["imported_bindings:all"].invoke

    puts ""
    puts "=== Step 5/5: verify bindings up-to-date ==="
    Rake::Task["bindgen:check:all"].invoke rescue nil
    Rake::Task["imported_bindings:check:all"].invoke rescue nil

    puts ""
    puts "done. #{source_name} upgraded to #{hash}."
    puts "review changes with: git diff std/"
  end

  desc 'List all upstream sources and their current pinned revisions'
  task :list do
    overrides = MilkTea::UpstreamSources.load_version_overrides
    MilkTea::UpstreamSources.default_sources.each do |source|
      overridden = overrides.key?(source.name)
      marker = overridden ? " [OVERRIDDEN]" : ""
      puts "#{source.name}: #{source.revision}#{marker}"
    end
  end

  desc 'Remove a version override, reverting to the hardcoded default revision'
  task :revert, [:source] do |_t, args|
    source_name = args[:source]
    unless source_name
      puts "usage: rake deps:revert[source_name]"
      exit 1
    end

    MilkTea::UpstreamSources.remove_version_override(source_name)
    puts "removed override for #{source_name} — next bootstrap will use hardcoded default revision"
  end
end

namespace :tools do
  desc 'Build all vendored tool binaries (e.g. tracy-profiler) and install into bin/'
  task :build do
    results = MilkTea::VendoredTools.build_all!(root: MilkTea.root)
    results.each do |result|
      puts "built #{result[:tool].name} -> #{result[:binary]}"
    end
  end
end

namespace :imported_bindings do
  desc 'Regenerate all checked-in imported binding modules'
  task all: IMPORTED_BINDINGS.task_names

  namespace :check do
    desc 'Check all checked-in imported binding modules'
    task all: IMPORTED_BINDINGS.check_task_names
  end

  IMPORTED_BINDINGS.each do |binding|
    desc "Regenerate #{binding.binding_path} from #{binding.raw_module_name} and #{binding.policy_path}"
    task binding.name.to_sym do
      raw_module_path = binding.write!
      puts "generated #{raw_module_path} + #{binding.policy_path} -> #{binding.binding_path}"
    end

    namespace :check do
      desc "Check that #{binding.binding_path} matches the current imported binding policy"
      task binding.name.to_sym do
        raw_module_path = binding.check!
        puts "verified #{binding.binding_path} matches #{raw_module_path} + #{binding.policy_path}"
      end
    end
  end
end

namespace :release do
  desc "Build and publish the gem to RubyGems.org"
  task :push do
    sh "gem build milk_tea.gemspec"
    gem_file = Dir["milk_tea-*.gem"].sort_by { |f| File.mtime(f) }.last
    sh "gem push #{gem_file}"
  end
end

namespace :bindgen do
  desc 'Regenerate all checked-in raw binding modules'
  task all: RAW_BINDINGS.task_names

  namespace :check do
    desc 'Check all checked-in raw binding modules'
    task all: RAW_BINDINGS.check_task_names
  end

  RAW_BINDINGS.each do |binding|
    desc "Regenerate #{binding.binding_path} from the installed #{binding.header_label}"
    task binding.name.to_sym do
      header_path = binding.write!
      report_path = binding.write_nullable_policy_report!(env: ENV, header_path: header_path)
      puts "generated #{header_path} -> #{binding.binding_path}"
      puts "nullable report #{header_path} -> #{report_path}"
    end

    namespace :check do
      desc "Check that #{binding.binding_path} matches current bindgen output"
      task binding.name.to_sym do
        header_path = binding.check!
        puts "verified #{binding.binding_path} matches bindgen output from #{header_path}"
      end
    end

    task "check_#{binding.name}".to_sym => binding.check_task_name
  end
end
