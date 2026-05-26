# frozen_string_literal: true

require "fileutils"
require "tempfile"

module MilkTea
  module PackageAtomicWrite
    module_function

    def write(path, content, binmode: false)
      open(path, binmode:) do |file|
        file.write(content)
      end
    end

    def open(path, binmode: false)
      expanded_path = File.expand_path(path)
      directory = File.dirname(expanded_path)

      FileUtils.mkdir_p(directory)

      Tempfile.create(["milk-tea-package", File.extname(expanded_path)], directory) do |file|
        file.binmode if binmode
        yield file

        unless file.closed?
          file.flush
          file.fsync
          file.close
        end

        replace(file.path, expanded_path)
      end

      expanded_path
    end

    def replace(source_path, destination_path)
      File.rename(source_path, destination_path)
    rescue Errno::EACCES, Errno::EEXIST, Errno::EPERM
      replace_via_backup(source_path, destination_path)
    end

    def replace_via_backup(source_path, destination_path)
      backup_path = "#{destination_path}.bak.#{$$}.#{Thread.current.object_id}"

      File.rename(destination_path, backup_path) if File.exist?(destination_path)

      begin
        File.rename(source_path, destination_path)
      rescue SystemCallError
        if File.exist?(backup_path) && !File.exist?(destination_path)
          File.rename(backup_path, destination_path)
        end
        raise
      end

      File.delete(backup_path) if File.exist?(backup_path)
    rescue Errno::ENOENT
      nil
    end
  end
end
