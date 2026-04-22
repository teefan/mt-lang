require 'rake/testtask'
require_relative 'lib/milk_tea'

RAW_BINDINGS = MilkTea::RawBindings.default_registry(root: MilkTea.root)

task default: :test
task verify: [:test, *RAW_BINDINGS.check_task_names]

Rake::TestTask.new do |t|
  t.libs << 'test'
  t.pattern = 'test/**/*_test.rb'
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
