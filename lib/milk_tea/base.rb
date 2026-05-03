# frozen_string_literal: true

require "pathname"

module MilkTea
  def self.root
    @root ||= Pathname.new(File.expand_path("../..", __dir__))
  end

  # Unified diagnostic value shared by the linter, sema, and all CFG analyses.
  # severity: :error | :warning | :hint | :info
  Diagnostic = Data.define(:path, :line, :column, :length, :code, :message, :severity, :symbol_name) do
    def initialize(path:, line:, column: nil, length: nil, code:, message:, severity: :warning, symbol_name: nil) = super

    def error?   = severity == :error
    def warning? = severity == :warning
    def hint?    = severity == :hint
    def info?    = severity == :info
  end
end
