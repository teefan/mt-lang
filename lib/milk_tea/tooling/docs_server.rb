# frozen_string_literal: true

require "socket"

module MilkTea
  class DocsServer
    HOST = "127.0.0.1"
    DEFAULT_IDLE_TIMEOUT = 7200

    def initialize(root_dir:, host: HOST, port: nil, idle_timeout: DEFAULT_IDLE_TIMEOUT)
      @root_dir = File.expand_path(root_dir)
      @host = host
      @port = port
      @idle_timeout = idle_timeout
      @server = nil
      @thread = nil
      @running = false
    end

    attr_reader :host, :port

    def start
      @server = TCPServer.new(@host, @port || 0)
      @port = @server.addr[1]
      @running = true
      @thread = Thread.new { serve }
      self
    rescue StandardError
      stop
      raise
    end

    def stop
      @running = false
      wake_server
      @thread&.join(1)
      @thread = nil
      close_server
      nil
    end

    def running?
      @running
    end

    def url
      "http://#{@host}:#{@port}/"
    end

    def join
      @thread&.join
    end

    private

    def serve
      last_request_at = Time.now
      trap_signals

      while @running
        if @idle_timeout.positive? && Time.now - last_request_at > @idle_timeout
          break
        end

        readable, = IO.select([@server], nil, nil, 0.25)
        next unless readable

        begin
          client = @server.accept
        rescue IOError, Errno::EBADF
          break
        end

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
    end

    def handle_client(socket)
      request_line = socket.gets
      return unless request_line

      method, target, = request_line.split(" ", 3)
      while (header = socket.gets)
        break if header == "\r\n"
      end

      unless %w[GET HEAD].include?(method)
        write_response(socket, 405, "Method Not Allowed", "method not allowed\n")
        return
      end

      path, is_dir = resolve_path(target)

      if is_dir
        serve_directory(socket, path, target, method)
        return
      end

      unless path && File.file?(path)
        write_response(socket, 404, "Not Found", "not found\n")
        return
      end

      body = File.binread(path)
      socket.write("HTTP/1.1 200 OK\r\n")
      socket.write("Content-Type: #{mime_type_for(path)}\r\n")
      socket.write("Content-Length: #{body.bytesize}\r\n")
      socket.write("Connection: close\r\n")
      socket.write("\r\n")
      socket.write(body) if method == "GET"
    end

    def resolve_path(target)
      path = target.to_s.split("?", 2).first
      path = "/" if path.empty?
      relative = path.delete_prefix("/")
      relative = "index.html" if relative.empty?
      candidate = File.expand_path(relative, @root_dir)
      return nil, false unless candidate.start_with?(@root_dir)

      if File.directory?(candidate)
        index = File.join(candidate, "index.html")
        if File.file?(index)
          [index, false]
        else
          [candidate, true]
        end
      else
        [candidate, false]
      end
    end

    def mime_type_for(path)
      case File.extname(path).downcase
      when ".html", ".htm" then "text/html; charset=utf-8"
      when ".css"  then "text/css; charset=utf-8"
      when ".js"   then "text/javascript; charset=utf-8"
      when ".json" then "application/json; charset=utf-8"
      when ".svg"  then "image/svg+xml"
      when ".png"  then "image/png"
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".gif"  then "image/gif"
      when ".ico"  then "image/x-icon"
      when ".wasm" then "application/wasm"
      when ".md"   then "text/markdown; charset=utf-8"
      when ".woff2" then "font/woff2"
      when ".woff"  then "font/woff"
      else "application/octet-stream"
      end
    end

    def serve_directory(socket, dir_path, target, method)
      entries = Dir.children(dir_path).sort
      body = +""
      body << "<!DOCTYPE html>\n<html>\n<head><meta charset=\"utf-8\"><title>Index of #{h(target)}</title></head>\n"
      body << "<body>\n<h1>Index of #{h(target)}</h1>\n<hr>\n<pre>\n"

      entries.each do |entry|
        full = File.join(dir_path, entry)
        trailing = File.directory?(full) ? "/" : ""
        body << "<a href=\"#{h(entry)}#{trailing}\">#{h(entry)}#{trailing}</a>\n"
      end

      body << "</pre>\n<hr>\n</body>\n</html>"

      socket.write("HTTP/1.1 200 OK\r\n")
      socket.write("Content-Type: text/html; charset=utf-8\r\n")
      socket.write("Content-Length: #{body.bytesize}\r\n")
      socket.write("Connection: close\r\n")
      socket.write("\r\n")
      socket.write(body) if method == "GET"
    end

    def write_response(socket, status, message, body)
      socket.write("HTTP/1.1 #{status} #{message}\r\n")
      socket.write("Content-Type: text/plain; charset=utf-8\r\n")
      socket.write("Content-Length: #{body.bytesize}\r\n")
      socket.write("Connection: close\r\n")
      socket.write("\r\n")
      socket.write(body)
    end

    def h(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end

    def trap_signals
      Signal.trap("TERM") { @running = false }
      Signal.trap("INT") { @running = false }
    rescue ArgumentError
      nil
    end

    def wake_server
      return unless @server && @port

      TCPSocket.new(@host, @port).close
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
end
