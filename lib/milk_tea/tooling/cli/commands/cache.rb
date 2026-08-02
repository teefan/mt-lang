# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandCache
      def cache_command
        subcommand = @argv.shift
        unless subcommand
          @err.puts("missing cache subcommand")
          print_command_help("cache", @err)
          return 1
        end

        cache_root = MilkTea.data_root.join("tmp", "mtc-cache")

        case subcommand
        when "purge"
          if File.directory?(cache_root)
            FileUtils.rm_rf(cache_root)
            @out.puts("purged #{cache_root}")
          else
            @out.puts("cache is already empty")
          end
          0
        when "status"
          unless File.directory?(cache_root)
            @out.puts("cache directory does not exist: #{cache_root}")
            return 0
          end
          program_dirs = Dir.glob(File.join(cache_root, "programs", "*", "*")).select { |d| File.directory?(d) }
          binary_files = Dir.glob(File.join(cache_root, "binaries", "*", "*", "binary")).select { |f| File.file?(f) }
          total_size = (program_dirs + binary_files).sum { |p|
            File.file?(p) ? File.size(p) : Dir.glob(File.join(p, "**", "*")).sum { |f| File.file?(f) ? File.size(f) : 0 }
          }
          @out.puts("cache  #{program_dirs.length} programs, #{binary_files.length} binaries  (#{format_size(total_size)})")
          @out.puts("  root  #{cache_root}")
          0
        else
          @err.puts("unknown cache subcommand #{subcommand}")
          print_command_help("cache", @err)
          1
        end
      end
    end
  end
end
