# frozen_string_literal: true

module MilkTea
  module ErrorFormatter
    def self.format(error, path: nil, source: nil, color: true)
      return error.message unless error.respond_to?(:line) && error.line
      return error.message unless error.respond_to?(:column) && error.column

      path ||= error.respond_to?(:path) ? error.path : nil
      return error.message unless path

      line = error.line.to_i
      column = error.column.to_i
      length = error.respond_to?(:length) ? error.length.to_i : 0
      severity = error.respond_to?(:severity) ? error.severity : :error
      code = error.respond_to?(:code) ? error.code : nil

      source ||= read_source(path)
      return "#{severity_label(severity)}: #{error.message} at #{path}:#{line}:#{column}" unless source

      source_lines = source.split("\n", -1)
      source_line = source_lines[line - 1] || ""
      stripped = source_line.gsub(/\t/, " ")

      indent = " " * [column - 1, 0].max
      highlight = if length && length > 1
                    "^" + "~" * (length - 1)
                  else
                    "^"
                  end

      bold  = color ? "\e[1m"  : ""
      red   = color ? "\e[31m" : ""
      yellow = color ? "\e[33m" : ""
      cyan  = color ? "\e[36m" : ""
      reset = color ? "\e[0m"  : ""

      sev_color, sev_text = case severity
                            when :error   then [red,    "error"]
                            when :warning then [yellow, "warning"]
                            when :info    then [cyan,   "info"]
                            when :hint    then [cyan,   "hint"]
                            else               [red,    "error"]
                            end
      code_text = code ? " #{cyan}[#{code}]#{reset}" : ""

      [
        "#{sev_color}#{sev_text}#{code_text}#{reset}: #{error.message}",
        "  #{bold}-->#{reset} #{path}:#{line}:#{column}",
        "   #{bold}|#{reset}",
        "#{line.to_s.rjust(5)} #{bold}|#{reset} #{stripped}",
        "      #{bold}|#{reset} #{sev_color}#{indent}#{highlight}#{reset}",
      ].join("\n")
    end

    def self.read_source(path)
      File.read(path)
    rescue Errno::ENOENT, Errno::EISDIR
      nil
    end

    def self.severity_label(severity)
      case severity
      when :error   then "error"
      when :warning then "warning"
      when :info    then "info"
      when :hint    then "hint"
      else               "error"
      end
    end
  end
end
