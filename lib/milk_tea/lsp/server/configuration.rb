# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerConfiguration
        private

      def pull_client_configuration
        items = [
          { section: 'milkTea.format.mode' },
          { section: 'milkTea.lsp.dependencyResolution' },
          { section: 'milkTea.lsp.platform' },
          { section: 'milkTea.lsp.strictCurrentRootDiagnostics' },
        ]
        Protocol.send_request('workspace/configuration', { items: items }) do |result, error|
          if error
            warn "Configuration pull failed: #{error['message']}"
          elsif result.is_a?(Array)
            settings = {}
            items.each_with_index do |item, idx|
              value = result[idx]
              next if value.nil?
              section_parts = item[:section].split('.')
              current = settings
              section_parts[0...-1].each { |k| current = (current[k] ||= {}) }
              current[section_parts.last] = value
            end
            apply_configuration_settings(settings)
          end
        end
      end

      def apply_configuration_settings(settings)
        mode = formatter_mode_from_settings(settings)
        @format_mode = mode if mode

        dependency_resolution_mode = dependency_resolution_mode_from_settings(settings)
        apply_dependency_resolution_mode(dependency_resolution_mode) if dependency_resolution_mode

        platform_provided, platform_override = platform_override_from_settings(settings)
        apply_platform_override(platform_override) if platform_provided

        strict_root_provided, strict_root_enabled = strict_current_root_diagnostics_from_settings(settings)
        apply_strict_current_root_diagnostics(strict_root_enabled) if strict_root_provided
      end

      def formatter_mode_from_settings(settings)
        return nil unless settings.is_a?(Hash)

        mode =
          settings.dig('milkTea', 'format', 'mode') ||
          settings.dig('milk_tea', 'format', 'mode') ||
          settings.dig('format', 'mode')
        return nil unless mode

        normalized = mode.to_s.strip.downcase.to_sym
        return normalized if Formatter::MODES.include?(normalized)

        nil
      end

      def dependency_resolution_mode_from_settings(settings)
        return nil unless settings.is_a?(Hash)

        mode =
          settings.dig('milkTea', 'lsp', 'dependencyResolution') ||
          settings.dig('milk_tea', 'lsp', 'dependencyResolution') ||
          settings.dig('lsp', 'dependencyResolution')
        return nil unless mode

        normalized = DependencyResolution.normalize_mode(mode)
        return normalized if DependencyResolution::MODES.include?(normalized)

        nil
      end

      def platform_override_from_settings(settings)
        return [false, nil] unless settings.is_a?(Hash)

        value =
          settings.dig('milkTea', 'lsp', 'platform') ||
          settings.dig('milk_tea', 'lsp', 'platform') ||
          settings.dig('lsp', 'platform')
        return [false, nil] if value.nil?

        normalized = value.to_s.strip.downcase
        return [true, nil] if normalized.empty? || normalized == 'auto'

        [true, ModuleLoader.normalize_platform_name(normalized)]
      rescue ArgumentError
        [false, nil]
      end

      def strict_current_root_diagnostics_from_settings(settings)
        return [false, nil] unless settings.is_a?(Hash)

        value =
          settings.dig('milkTea', 'lsp', 'strictCurrentRootDiagnostics') ||
          settings.dig('milk_tea', 'lsp', 'strictCurrentRootDiagnostics') ||
          settings.dig('lsp', 'strictCurrentRootDiagnostics')
        return [false, nil] if value.nil?

        normalized = case value
                     when true, false
                       value
                     else
                       case value.to_s.strip.downcase
                       when 'true', '1', 'yes', 'on'
                         true
                       when 'false', '0', 'no', 'off', ''
                         false
                       else
                         return [false, nil]
                       end
                     end

        [true, normalized]
      end

      def apply_dependency_resolution_mode(mode)
        normalized = DependencyResolution.normalize_mode(mode)
        return if @dependency_resolution_mode == normalized

        @dependency_resolution_mode = normalized
        @workspace.dependency_resolution_mode = normalized
        @diagnostic_report_cache.clear
        @workspace_diagnostic_cache.clear
        open_uris = @workspace.open_document_uris
        invalidate_document_caches_for(open_uris)
        open_uris.each do |uri|
          schedule_diagnostics(uri, force: true, lint_tier: :full) unless @workspace.background_document?(uri)
        end
      end

      def apply_platform_override(platform)
        normalized = platform.nil? ? nil : ModuleLoader.normalize_platform_name(platform)
        return if @platform_override == normalized

        @platform_override = normalized
        @workspace.platform_override = normalized
        @diagnostic_report_cache.clear
        @workspace_diagnostic_cache.clear
        open_uris = @workspace.open_document_uris
        invalidate_document_caches_for(open_uris)
        open_uris.each do |uri|
          schedule_diagnostics(uri, force: true, lint_tier: :full) unless @workspace.background_document?(uri)
        end
      end

      def apply_strict_current_root_diagnostics(enabled)
        normalized = !!enabled
        return if @workspace.strict_current_root_diagnostics_enabled == normalized

        @workspace.strict_current_root_diagnostics_enabled = normalized
        @diagnostic_report_cache.clear
        @workspace_diagnostic_cache.clear
        open_uris = @workspace.open_document_uris
        invalidate_document_caches_for(open_uris)
        open_uris.each do |uri|
          schedule_diagnostics(uri, force: true, lint_tier: :full) unless @workspace.background_document?(uri)
        end
      end
      end
    end
  end
end
