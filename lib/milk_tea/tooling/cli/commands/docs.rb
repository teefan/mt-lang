# frozen_string_literal: true

module MilkTea
  class CLI
    module CommandDocs
      def docs_command
        port = nil
        open_flag = false

        while (arg = @argv.first)
          case arg
          when "--port", "-p"
            @argv.shift
            port = @argv.shift.to_i
            port = nil if port <= 0 || port > 65535
          when "--open", "-o"
            open_flag = true
            @argv.shift
          else
            break
          end
        end

        port = resolve_docs_port(port)

        DocsApp.set :port, port
        DocsApp.set :bind, "127.0.0.1"
        DocsApp.set :environment, :production
        DocsApp.set :server, :puma

        url = "http://127.0.0.1:#{port}/"

        @out.puts("Serving Milk Tea docs at #{url}")
        @out.puts("Press Ctrl+C to stop.")

        if open_flag
          open_browser(url)
        end

        DocsApp.run!
        0
      rescue Interrupt
        0
      end

      def resolve_docs_port(preferred)
        return preferred if preferred

        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        server.close
        port
      rescue StandardError
        4567
      end
    end
  end
end
