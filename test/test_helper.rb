# frozen_string_literal: true

require "cgi/escape"
require "minitest/autorun"
require "socket"
require_relative "../lib/milk_tea"

module MilkTeaStaticHttpServerHelper
	def with_static_http_server(root)
		server = TCPServer.new("127.0.0.1", 0)
		root_path = File.expand_path(root)
		errors = Queue.new

		thread = Thread.new do
			loop do
				client = server.accept
				serve_static_http_request(client, root_path)
			rescue IOError, Errno::EBADF
				break
			rescue StandardError => e
				errors << e
			ensure
				client&.close
			end
		end

		yield "http://127.0.0.1:#{server.local_address.ip_port}"
	ensure
		server&.close
		thread&.join(1)
		raise errors.pop unless errors.nil? || errors.empty?
	end

	private

	def serve_static_http_request(client, root_path)
		request_line = client.gets
		return unless request_line

		method, raw_path, = request_line.split(" ", 3)
		while (line = client.gets)
			break if line == "\r\n"
		end

		unless method == "GET"
			respond_http(client, 405, "Method Not Allowed", "method not allowed\n")
			return
		end

		relative_path = raw_path.to_s.split("?", 2).first
		segments = relative_path.split("/").reject(&:empty?).map { |segment| CGI.unescape(segment) }
		path = File.expand_path(File.join(root_path, *segments))
		unless path == root_path || path.start_with?(root_path + File::SEPARATOR)
			respond_http(client, 403, "Forbidden", "forbidden\n")
			return
		end

		unless File.file?(path)
			respond_http(client, 404, "Not Found", "not found\n")
			return
		end

		body = File.binread(path)
		content_type = path.end_with?(".txt", ".toml") ? "text/plain; charset=utf-8" : "application/octet-stream"
		client.write("HTTP/1.1 200 OK\r\n")
		client.write("Content-Type: #{content_type}\r\n")
		client.write("Content-Length: #{body.bytesize}\r\n")
		client.write("Connection: close\r\n")
		client.write("\r\n")
		client.write(body)
	end

	def respond_http(client, status, message, body)
		client.write("HTTP/1.1 #{status} #{message}\r\n")
		client.write("Content-Type: text/plain; charset=utf-8\r\n")
		client.write("Content-Length: #{body.bytesize}\r\n")
		client.write("Connection: close\r\n")
		client.write("\r\n")
		client.write(body)
	end
end

class Minitest::Test
	include MilkTeaStaticHttpServerHelper
end
