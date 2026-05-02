# frozen_string_literal: true

module MilkTea
  module ModuleRoots
    module_function

    def roots_for_path(path, env: ENV)
      roots = []

      add_env_roots!(roots, env)

      project_root = project_root_for_path(path)
      roots << project_root if project_root

      roots << MilkTea.root.to_s

      roots.map { |root| normalize_root(root) }
           .compact
           .uniq
           .select { |root| File.directory?(root) }
    end

    def project_root_for_path(path)
      return nil unless path

      current = File.expand_path(File.directory?(path) ? path : File.dirname(path))
      loop do
        return current if File.directory?(File.join(current, 'std'))

        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      end
    end

    def normalize_root(root)
      return nil if root.nil? || root.to_s.strip.empty?

      expanded = File.expand_path(root.to_s)
      if File.basename(expanded) == 'std'
        File.dirname(expanded)
      else
        expanded
      end
    end

    def add_env_roots!(roots, env)
      env_keys = %w[MILK_TEA_MODULE_ROOT MILK_TEA_STD_ROOT]
      env_keys.each do |key|
        value = env[key]
        next if value.nil? || value.strip.empty?

        value.split(File::PATH_SEPARATOR).each do |entry|
          roots << entry unless entry.strip.empty?
        end
      end
    end
    private_class_method :add_env_roots!
  end
end
