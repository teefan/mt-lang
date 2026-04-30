require 'rake/testtask'
require_relative 'lib/milk_tea'
require_relative 'lib/milk_tea/bindings'

RAW_BINDINGS = MilkTea::RawBindings.default_registry(root: MilkTea.root)
IMPORTED_BINDINGS = MilkTea::ImportedBindings.default_registry(root: MilkTea.root)

task default: :test
task verify: [:test, *RAW_BINDINGS.check_task_names, *IMPORTED_BINDINGS.check_task_names]

desc 'Run all tests'
Rake::TestTask.new do |t|
  t.libs << 'test'
  t.pattern = 'test/**/*_test.rb'
end

namespace :test do
  {
    compiler: 'test/compiler/**/*_test.rb',
    tooling: 'test/tooling/**/*_test.rb',
    std: 'test/std/**/*_test.rb',
    examples: 'test/examples/**/*_test.rb',
  }.each do |name, pattern|
    desc "Run #{name} tests"
    Rake::TestTask.new(name) do |t|
      t.libs << 'test'
      t.pattern = pattern
    end
  end
end

namespace :deps do
  desc 'Ensure vendored third_party upstream folders are present at the pinned revisions'
  task :bootstrap do
    MilkTea::UpstreamSources.bootstrap_all!.each do |result|
      verb = result.status == :present ? 'kept' : 'bootstrapped'
      puts "#{verb} #{result.source.name} -> #{result.path}"
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
      puts "generated #{header_path} -> #{binding.binding_path}"
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
