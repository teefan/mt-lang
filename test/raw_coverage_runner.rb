# frozen_string_literal: true

require 'coverage'
require 'fileutils'
require 'json'
require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__).freeze
LIB_ROOT = File.join(ROOT, 'lib').freeze
SUMMARY_PATH = ENV.fetch('MILK_TEA_RAW_COVERAGE_SUMMARY_PATH')
JSON_PATH = ENV.fetch('MILK_TEA_RAW_COVERAGE_JSON_PATH')
LOWEST_COVERAGE_LIMIT = 20

Coverage.start(lines: true)

ARGV.each do |path|
	load File.expand_path(path, ROOT)
end

def coverage_entries(result)
	result.each_with_object([]) do |(path, counts), files|
		next unless path.start_with?(LIB_ROOT + File::SEPARATOR)
		next unless File.file?(path)

		lines = counts.fetch(:lines) { counts.fetch('lines') }

		total_lines = lines.count { |count| !count.nil? }
		next if total_lines.zero?

		covered_lines = lines.count { |count| count.to_i.positive? }
		coverage = covered_lines * 100.0 / total_lines
		uncovered_lines = lines.each_index.filter_map do |index|
			line = lines[index]
			index + 1 if !line.nil? && line.to_i.zero?
		end

		files << {
			'path' => path.delete_prefix(ROOT + File::SEPARATOR),
			'covered_lines' => covered_lines,
			'total_lines' => total_lines,
			'coverage' => coverage.round(2),
			'uncovered_lines' => uncovered_lines,
		}
	end.sort_by { |file| [file['coverage'], -file['total_lines'], file['path']] }
end

def coverage_summary(files)
	covered_lines = files.sum { |file| file['covered_lines'] }
	total_lines = files.sum { |file| file['total_lines'] }
	coverage = total_lines.zero? ? 100.0 : covered_lines * 100.0 / total_lines

	{
		'covered_lines' => covered_lines,
		'total_lines' => total_lines,
		'coverage' => coverage.round(2),
	}
end

def summary_text(report)
	lines = []
	summary = report.fetch('summary')
	lines << format(
		'Total lib line coverage: %.2f%% (%d/%d)',
		summary.fetch('coverage'),
		summary.fetch('covered_lines'),
		summary.fetch('total_lines'),
	)
	lines << ''
	lines << "Lowest coverage files (top #{LOWEST_COVERAGE_LIMIT}):"
	report.fetch('files').first(LOWEST_COVERAGE_LIMIT).each do |file|
		lines << format(
			'%.2f%% (%d/%d) %s',
			file.fetch('coverage'),
			file.fetch('covered_lines'),
			file.fetch('total_lines'),
			file.fetch('path'),
		)
	end
	lines.join("\n") + "\n"
end

Minitest.after_run do
	report = {}
	report['files'] = coverage_entries(Coverage.result)
	report['summary'] = coverage_summary(report['files'])

	FileUtils.mkdir_p(File.dirname(JSON_PATH))
	FileUtils.mkdir_p(File.dirname(SUMMARY_PATH))
	File.write(JSON_PATH, JSON.pretty_generate(report))
	text = summary_text(report)
	File.write(SUMMARY_PATH, text)
	puts text
end
