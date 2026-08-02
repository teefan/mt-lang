# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandSnapshot
      def snapshot_command
        input_path = nil
        theme_path = nil
        output_path = nil
        textmate_only = false

        until @argv.empty?
          arg = @argv.first
          case arg
          when "--theme", "-t"
            @argv.shift
            theme_path = @argv.shift
            unless theme_path
              @err.puts("snapshot: missing value for --theme")
              return 1
            end
          when "--output", "-o"
            @argv.shift
            output_path = @argv.shift
            unless output_path
              @err.puts("snapshot: missing value for --output")
              return 1
            end
          when "--textmate-only"
            @argv.shift
            textmate_only = true
          else
            if arg.start_with?("-")
              @err.puts("snapshot: unknown option #{arg}")
              return 1
            end
            unless input_path
              input_path = @argv.shift
            else
              @err.puts("snapshot: unexpected argument #{@argv.shift}")
              return 1
            end
          end
        end

        unless input_path
          @err.puts("snapshot: missing source file path")
          print_usage(@err)
          return 1
        end

        unless File.file?(input_path)
          @err.puts("snapshot: source file not found: #{input_path}")
          return 1
        end

        input_path = File.expand_path(input_path)
        theme_path = File.expand_path(theme_path) if theme_path
        output_path = File.expand_path(output_path) if output_path

        if theme_path && !File.file?(theme_path)
          @err.puts("snapshot: theme file not found: #{theme_path}")
          return 1
        end

        snapshot_script = MilkTea.root.join("bindings/vscode/scripts/snapshot.js").to_s
        unless File.file?(snapshot_script)
          @err.puts("snapshot: internal script not found at #{snapshot_script}")
          return 1
        end

        args = ["node", snapshot_script, input_path]
        args.push("-t", theme_path) if theme_path
        args.push("-o", output_path) if output_path

        semantic_result = nil
        unless textmate_only
          begin
            semantic_result = MilkTea::LSP::Server.semantic_tokens_for_path(input_path)
          rescue => e
            @err.puts("snapshot: semantic analysis skipped: #{e.message}")
          end
        end

        if semantic_result && semantic_result[:entries] && !semantic_result[:entries].empty?
          source = File.read(input_path)
          lines = source.split("\n", -1)
          semantic_result[:entries].each do |entry|
            byte_start = entry[:startChar]
            byte_len = entry[:length]
            line_text = lines[entry[:line]]
            unless line_text && byte_start && byte_len
              entry[:startChar] = 0
              entry[:length] = 0
              next
            end
            char_start = line_text.byteslice(0, byte_start).length
            char_length = line_text.byteslice(byte_start, byte_len).length
            char_length = line_text.length - char_start if char_start + char_length > line_text.length
            entry[:startChar] = char_start
            entry[:length] = char_length
          end

          temp = Tempfile.new(["mt_semantic", ".json"])
          temp.write(JSON.generate(semantic_result[:entries]))
          temp.close
          args.push("-s", temp.path)
          system(*args)
          temp.unlink
        else
          system(*args)
        end
        $?.success? ? 0 : 1
      end
    end
  end
end
