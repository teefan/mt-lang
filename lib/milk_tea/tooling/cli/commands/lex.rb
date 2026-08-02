# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandLex
      def lex_command
        path = nil
        sexpr = false

        args = @argv.dup
        @argv = []
        until args.empty?
          arg = args.shift
          next if arg == "--"

          if arg == "--sexpr"
            sexpr = true
            next
          end

          if path.nil?
            path = arg
          else
            @err.puts("unknown option: #{arg}")
            print_usage(@err)
            return 1
          end
        end

        unless path
          @err.puts("missing source file path")
          print_usage(@err)
          return 1
        end

        tokens = Lexer.lex(read_source_file(path), path: path)
        if sexpr
          @out.puts(SexprDumper.dump_tokens(tokens))
        else
          @out.write(PP.pp(tokens, +""))
        end
        0
      end
    end
  end
end
