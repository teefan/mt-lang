# frozen_string_literal: true

module MilkTea
  module LSP
    class DependencyResolution
      MODES = %i[auto live locked frozen].freeze

      Resolved = Data.define(:mode, :locked, :error_message) do
        def ok?
          error_message.nil?
        end
      end

      def self.normalize_mode(mode)
        normalized = mode.to_s.strip.downcase.to_sym
        MODES.include?(normalized) ? normalized : :auto
      end

      def self.resolve(path, mode: :auto)
        normalized_mode = normalize_mode(mode)
        return Resolved.new(mode: normalized_mode, locked: false, error_message: nil) unless path && File.file?(path)

        case normalized_mode
        when :live
          Resolved.new(mode: normalized_mode, locked: false, error_message: nil)
        when :auto
          lock_result = PackageLock.check(path)
          Resolved.new(mode: normalized_mode, locked: lock_result.current?, error_message: nil)
        when :locked
          Resolved.new(mode: normalized_mode, locked: true, error_message: nil)
        when :frozen
          lock_result = PackageLock.check(path)
          if lock_result.current?
            Resolved.new(mode: normalized_mode, locked: true, error_message: nil)
          elsif lock_result.missing?
            Resolved.new(mode: normalized_mode, locked: true, error_message: "package.lock is missing: #{lock_result.lock_path}")
          else
            Resolved.new(mode: normalized_mode, locked: true, error_message: "package.lock is out of date: #{lock_result.lock_path}")
          end
        end
      rescue PackageManifestError
        Resolved.new(mode: normalized_mode, locked: false, error_message: nil)
      rescue PackageLockError => e
        if normalized_mode == :auto
          Resolved.new(mode: normalized_mode, locked: false, error_message: nil)
        else
          Resolved.new(mode: normalized_mode, locked: true, error_message: e.message)
        end
      end
    end
  end
end
