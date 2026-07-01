# frozen_string_literal: true

require "pathname"

module MilkTea
  VERSION = "0.1.0"

  def self.root
    @root ||= Pathname.new(File.expand_path("../..", __dir__))
  end

  def self.data_root
    @data_root ||= begin
      if File.writable?(root.to_s)
        root
      else
        xdg_cache = ENV.fetch("XDG_CACHE_HOME", File.join(Dir.home, ".cache"))
        Pathname.new(File.join(xdg_cache, "milk_tea"))
      end
    end
  end

  def self.writable_root_for(root)
    resolved = Pathname.new(File.expand_path(root.to_s))
    if resolved.to_s == MilkTea.root.to_s
      data_root
    else
      resolved
    end
  end

  def self.host_platform
    return :windows if /mswin|mingw|cygwin/ === RUBY_PLATFORM
    return :darwin if /darwin/ === RUBY_PLATFORM

    :linux
  end

  # Unified diagnostic value shared by the linter, sema, and all ControlFlow analyses.
  # severity: :error | :warning | :hint | :info
  Diagnostic = Data.define(:path, :line, :column, :length, :code, :message, :severity, :symbol_name) do
    def initialize(path:, line:, column: nil, length: nil, code:, message:, severity: :warning, symbol_name: nil) = super

    def error?   = severity == :error
    def warning? = severity == :warning
    def hint?    = severity == :hint
    def info?    = severity == :info
  end
end
