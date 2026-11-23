# frozen_string_literal: true

# Golden fixtures for the parity sweeps' recorded mode.
#
# `--record FILE` writes the system-under-test's normalized results once.
# `--expect FILE` replays them without consulting the Ruby host, so the gate
# keeps working after the host is retired.  A mismatch is a behavior change
# that must be reviewed and re-recorded, not a host disagreement.
require "fileutils"
require "json"

module Golden
  FORMAT = 1

  def self.write(path, gate, data)
    FileUtils.mkdir_p(File.dirname(path))
    payload = { "format" => FORMAT, "gate" => gate, "data" => data }
    File.write(path, JSON.pretty_generate(payload) << "\n")
    path
  end

  def self.read(path, gate)
    payload = JSON.parse(File.read(path))
    unless payload.is_a?(Hash) && payload["format"] == FORMAT
      raise "golden fixture #{path}: unsupported format (expected #{FORMAT})"
    end
    unless payload["gate"] == gate
      raise "golden fixture #{path}: belongs to #{payload['gate'].inspect}, not #{gate.inspect}"
    end

    payload["data"]
  end

  # Recursive structural diff over the JSON shapes the sweeps record (hashes,
  # arrays, strings, integers).  `limit` caps the number of reported lines.
  def self.diff(expected, actual, limit: 40)
    out = []
    diff_into(out, expected, actual, "", limit)
    out
  end

  def self.diff_into(out, expected, actual, path, limit)
    return if out.length >= limit

    if expected.is_a?(Hash) && actual.is_a?(Hash)
      (expected.keys | actual.keys).sort.each do |key|
        return if out.length >= limit

        child = path.empty? ? key.to_s : "#{path}.#{key}"
        if !actual.key?(key)
          out << "#{child}: missing"
        elsif !expected.key?(key)
          out << "#{child}: unexpected"
        else
          diff_into(out, expected[key], actual[key], child, limit)
        end
      end
    elsif expected.is_a?(Array) && actual.is_a?(Array)
      label = path.empty? ? "<root>" : path
      out << "#{label}: length #{expected.length} != #{actual.length}" if expected.length != actual.length
      [expected.length, actual.length].min.times do |index|
        return if out.length >= limit

        diff_into(out, expected[index], actual[index], "#{path}[#{index}]", limit)
      end
    elsif expected != actual
      label = path.empty? ? "<root>" : path
      out << "#{label}: expected #{expected.inspect}, got #{actual.inspect}"
    end
  end
end
