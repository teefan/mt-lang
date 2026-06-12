# frozen_string_literal: true

require "open3"
require "socket"
require "tmpdir"

module MilkTea
  class RunError < StandardError; end

  class Run
    class WasmPreviewServer
      HOST = "127.0.0.1"
      DEFAULT_IDLE_TIMEOUT = 600

      def initialize(root_dir:, host: HOST, port: nil, idle_timeout: DEFAULT_IDLE_TIMEOUT)
        @root_dir = File.expand_path(root_dir)
        @host = host
        @port = port
        @idle_timeout = idle_timeout
        @thread = nil
        @server = nil
        @running = false
      end

      attr_reader :host, :port

      def start
        listen!
        @thread = Thread.new { serve_forever(trap_signals: false) }
        self
      rescue StandardError
        stop
        raise
      end

      def stop
        @running = false
        if @thread
          wake_server
          @thread.join(1)
        end
        @thread = nil
        close_server
        nil
      end

      def listen!
        return self if @server

        @server = TCPServer.new(@host, @port || 0)
        @port = @server.addr[1]
        self
      end

      def url_for(entry_name)
        raise RunError, "wasm preview server has not been started" unless @port

        "http://#{@host}:#{@port}/#{entry_name}"
      end

      def serve_forever(trap_signals: true)
        listen!
        @running = true
        previous_handlers = trap_signals ? install_signal_handlers : nil
        last_request_at = Time.now

        while @running
          if @idle_timeout.positive? && Time.now - last_request_at > @idle_timeout
            break
          end

          readable, = IO.select([@server], nil, nil, 0.25)
          next unless readable

          client = @server.accept
          Thread.new(client) do |socket|
            begin
              handle_client(socket)
            ensure
              last_request_at = Time.now
              socket.close unless socket.closed?
            end
          end
        end
      ensure
        close_server
        restore_signal_handlers(previous_handlers) if previous_handlers
      end

      private

      def handle_client(socket)
        request_line = socket.gets
        return unless request_line

        method, target, = request_line.split(" ", 3)
        while (header = socket.gets)
          break if header == "\r\n"
        end

        unless ["GET", "HEAD"].include?(method)
          write_response(socket, 405, "Method Not Allowed", "method not allowed\n")
          return
        end

        path = resolve_request_path(target)
        unless path && File.file?(path)
          write_response(socket, 404, "Not Found", "not found\n")
          return
        end

        body = File.binread(path)
        headers = {
          "Content-Type" => mime_type_for(path),
          "Content-Length" => body.bytesize.to_s,
          "Cache-Control" => "no-cache",
          "Cross-Origin-Opener-Policy" => "same-origin",
          "Cross-Origin-Embedder-Policy" => "require-corp",
          "Connection" => "close",
        }

        socket.write("HTTP/1.1 200 OK\r\n")
        headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
        socket.write("\r\n")
        socket.write(body) if method == "GET"
      end

      def resolve_request_path(target)
        request_path = target.to_s.split("?", 2).first
        request_path = "/" if request_path.empty?
        relative = request_path == "/" ? default_entry_name : request_path.delete_prefix("/")
        candidate = File.expand_path(relative, @root_dir)
        return nil unless candidate.start_with?(@root_dir + File::SEPARATOR) || candidate == @root_dir

        candidate
      end

      def default_entry_name
        html_entries = Dir.children(@root_dir).grep(/\.html\z/).sort
        html_entries.first || "index.html"
      end

      def mime_type_for(path)
        case File.extname(path)
        when ".html"
          "text/html; charset=utf-8"
        when ".js"
          "text/javascript; charset=utf-8"
        when ".css"
          "text/css; charset=utf-8"
        when ".json", ".mtdbg.json"
          "application/json; charset=utf-8"
        when ".wasm"
          "application/wasm"
        when ".wav"
          "audio/wav"
        when ".png"
          "image/png"
        when ".ppm"
          "image/x-portable-pixmap"
        else
          "application/octet-stream"
        end
      end

      def write_response(socket, status, message, body)
        body ||= ""
        socket.write("HTTP/1.1 #{status} #{message}\r\n")
        socket.write("Content-Type: text/plain; charset=utf-8\r\n")
        socket.write("Content-Length: #{body.bytesize}\r\n")
        socket.write("Cross-Origin-Opener-Policy: same-origin\r\n")
        socket.write("Cross-Origin-Embedder-Policy: require-corp\r\n")
        socket.write("Connection: close\r\n")
        socket.write("\r\n")
        socket.write(body)
      end

      def install_signal_handlers
        {
          "TERM" => Signal.trap("TERM") { @running = false },
          "INT" => Signal.trap("INT") { @running = false },
        }
      end

      def restore_signal_handlers(previous_handlers)
        previous_handlers.each do |signal_name, handler|
          Signal.trap(signal_name, handler)
        end
      rescue ArgumentError
        nil
      end

      def wake_server
        return unless @server && @port

        socket = TCPSocket.new(@host, @port)
        socket.close
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        nil
      end

      def close_server
        @server&.close
      rescue IOError, Errno::EBADF
        nil
      ensure
        @server = nil
      end
    end

    Result = Data.define(:stdout, :stderr, :exit_status, :output_path, :c_path, :compiler, :link_flags, :platform, :bundle_root, :archive_path, :cached)

    def self.run(path, output_path: nil, cc: ENV.fetch("CC", "cc"), keep_c_path: nil, module_roots: nil, package_graph: nil, frontend: nil, profile: nil, platform: nil, bundle: false, archive: false, browser_opener: nil, preview_server_class: nil, preview_started: nil, argv: [], no_cache: false, kind: :executable)
      new(path, output_path:, cc:, keep_c_path:, module_roots:, package_graph:, frontend:, profile:, platform:, bundle:, archive:, browser_opener:, preview_server_class:, preview_started:, argv:, no_cache:, kind:).run
    end

    def initialize(path, output_path:, cc:, keep_c_path:, module_roots: nil, package_graph: nil, frontend: nil, profile: nil, platform: nil, bundle: false, archive: false, browser_opener: nil, preview_server_class: nil, preview_started: nil, argv: [], no_cache: false, kind: :executable)
      @input_path = File.expand_path(path)
      @output_path = output_path ? File.expand_path(output_path) : nil
      @cc = cc
      @keep_c_path = keep_c_path ? File.expand_path(keep_c_path) : nil
      @module_roots = module_roots
      @project_root = resolve_project_root
      @package_graph = package_graph
      @frontend = frontend
      @profile = profile
      @platform = platform
      @bundle = bundle
      @archive = archive
      @browser_opener = browser_opener || method(:open_browser)
      @preview_server_class = preview_server_class || WasmPreviewServer
      @preview_started = preview_started
      @argv = argv
      @no_cache = no_cache
    end

    def run
      if @output_path
        return run_binary(@output_path)
      end

      if wasm_target_requested?
        return run_binary(nil)
      end

      Dir.mktmpdir("milk-tea-run") do |dir|
        binary_path = File.join(dir, File.basename(@input_path, ".mt"))
        run_binary(binary_path)
      end
    end

    private

    def resolve_project_root
      candidate = File.directory?(@input_path) ? @input_path : File.dirname(@input_path)
      return candidate if File.directory?(candidate)

      Array(@module_roots).map { |root| File.expand_path(root.to_s) }.find { |root| File.directory?(root) } || Dir.pwd
    end

    def run_binary(binary_path)
      build_result = Build.build(
        @input_path,
        output_path: binary_path,
        cc: @cc,
        keep_c_path: @keep_c_path,
        module_roots: @module_roots,
        package_graph: @package_graph,
        frontend: @frontend,
        profile: @profile,
        platform: @platform,
        bundle: @bundle,
        archive: @archive,
        no_cache: @no_cache,
      )
      return run_wasm_preview(build_result) if build_result.platform == :wasm

      unless build_result.platform == host_platform
        raise RunError, "run target platform is #{build_result.platform}; host platform is #{host_platform}"
      end

      out_buf = String.new
      err_buf = String.new
      status = nil
      live = $stdout.tty?

      cmd = [build_result.output_path, *@argv]
      cmd = ["stdbuf", "-oL", "-eL", *cmd] if host_platform == :linux

      Open3.popen3(*cmd, chdir: @project_root) do |stdin, stdout, stderr, wait_thr|
        stdin.close

        out_thread = Thread.new do
          Thread.current.report_on_exception = false
          while (chunk = stdout.readpartial(4096))
            $stdout.write(chunk) if live
            $stdout.flush if live
            out_buf << chunk
          end
        rescue EOFError, IOError
        end

        err_thread = Thread.new do
          Thread.current.report_on_exception = false
          while (chunk = stderr.readpartial(4096))
            $stderr.write(chunk) if live
            $stderr.flush if live
            err_buf << chunk
          end
        rescue EOFError, IOError
        end

        begin
          status = wait_thr.value
        rescue Interrupt
          Process.kill("TERM", wait_thr.pid) rescue nil
          begin
            status = wait_thr.value
          rescue Interrupt
            Process.kill("KILL", wait_thr.pid) rescue nil
            status = wait_thr.value
          end
        end

        out_thread.join
        err_thread.join
      end

      Result.new(
        stdout: out_buf,
        stderr: err_buf,
        exit_status: process_exit_status(status),
        output_path: @output_path,
        c_path: build_result.c_path,
        compiler: build_result.compiler,
        link_flags: build_result.link_flags,
        platform: build_result.platform,
        bundle_root: build_result.bundle_root,
        archive_path: build_result.archive_path,
        cached: build_result.cached,
      )
    rescue Errno::ENOENT
      raise RunError, "built program not found: #{binary_path}"
    end

    def process_exit_status(status)
      return status.exitstatus if status.exited?
      return 128 + status.termsig if status.signaled?

      1
    end

    def run_wasm_preview(build_result)
      preview_server = @preview_server_class.new(root_dir: File.dirname(build_result.output_path), idle_timeout: 0)
      preview_server.listen! if preview_server.respond_to?(:listen!)
      url = preview_server.url_for(File.basename(build_result.output_path))
      startup_message = "serving #{url} (press Ctrl-C to stop)\n"
      @browser_opener.call(url)
      @preview_started&.call(startup_message)
      preview_server.serve_forever

      Result.new(
        stdout: startup_message,
        stderr: "",
        exit_status: 0,
        output_path: build_result.output_path,
        c_path: build_result.c_path,
        compiler: build_result.compiler,
        link_flags: build_result.link_flags,
        platform: build_result.platform,
        bundle_root: build_result.bundle_root,
        archive_path: build_result.archive_path,
        cached: build_result.cached,
      )
    rescue StandardError
      preview_server&.stop if preview_server&.respond_to?(:stop)
      raise
    end

    def open_browser(url)
      command = browser_open_command(url)
      pid = Process.spawn(*command, out: File::NULL, err: File::NULL)
      Process.detach(pid)
    rescue Errno::ENOENT
      raise RunError, "browser launcher not found: #{command.first}"
    end

    def browser_open_command(url)
      return ["cmd", "/c", "start", "", url] if host_platform == :windows

      ["xdg-open", url]
    end

    def wasm_target_requested?
      return true if @platform && @platform.to_s == "wasm"

      PackageManifest.load(@input_path).platform == :wasm
    rescue PackageManifestError
      false
    end

    def host_platform
      MilkTea.host_platform
    end
  end
end
