# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "minitest/autorun"
require "socket"
require_relative "../lib/milk_tea"

module MilkTeaGeneratedFixtureHelper
	module_function

	LANGUAGE_FIXTURE_SOURCE = <<~MT.freeze

		import test.fixtures.language_fixture.external_runtime as runtime
		import test.fixtures.language_fixture.types as types

		const default_step: int = 3

		type ExitCode = int

		struct AppState:
		    counter: types.Counter
		    touched: bool

		extending AppState:
		    static function create() -> AppState:
		        return AppState(counter = types.Counter.zero(), touched = false)

		    mutable function touch(step: int) -> void:
		        this.counter.bump(step)
		        this.touched = true

		    function read() -> int:
		        return this.counter.total

		function describe(state: AppState) -> Result[int, int]:
		    if state.touched:
		        return Result[int, int].success(value= state.read())
		    return Result[int, int].failure(error= 9)

		function main() -> ExitCode:
		    var state = AppState.create()
		    defer state.touch(0)
		    state.touch(default_step)
		    let maybe_value = Option[int].some(value= state.read())
		    runtime.puts(c"fixture")
		    match maybe_value:
		        Option.none:
		            return 1
		        Option.some as payload:
		            let checked = describe(state)
		            match checked:
		                Result.success as result:
		                    return payload.value + result.value - default_step
		                Result.failure as result:
		                    return result.error
		    return 2
	MT

	LANGUAGE_FIXTURE_TYPES_SOURCE = <<~MT.freeze
		public struct Counter:
		    total: int

		extending Counter:
		    public static function zero() -> Counter:
		        return Counter(total = 0)

		    public mutable function bump(step: int) -> void:
		        this.total += step
	MT

	LANGUAGE_FIXTURE_EXTERNAL_RUNTIME_SOURCE = <<~MT.freeze
		external

		include "stdio.h"

		external function puts(text: cstr) -> int
	MT

	def materialized_language_fixture_path
		ensure_language_fixture_tree!
		File.join(fixture_root, "language_fixture.mt")
	end

	def fixture_root
		File.expand_path("fixtures", __dir__)
	end

	def ensure_language_fixture_tree!
		fixture_dir = File.join(fixture_root, "language_fixture")
		FileUtils.mkdir_p(fixture_dir)
		File.write(File.join(fixture_root, "language_fixture.mt"), LANGUAGE_FIXTURE_SOURCE)
		File.write(File.join(fixture_dir, "types.mt"), LANGUAGE_FIXTURE_TYPES_SOURCE)
		File.write(File.join(fixture_dir, "external_runtime.mt"), LANGUAGE_FIXTURE_EXTERNAL_RUNTIME_SOURCE)
		@generated_fixture_tree = true
		register_fixture_cleanup!
	end

	def register_fixture_cleanup!
		return if @fixture_cleanup_registered

		@fixture_cleanup_registered = true
		at_exit do
			FileUtils.rm_rf(fixture_root) if @generated_fixture_tree
		end
	end
	private_class_method :ensure_language_fixture_tree!
	private_class_method :register_fixture_cleanup!
end

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

	def materialized_language_fixture_path
		MilkTeaGeneratedFixtureHelper.materialized_language_fixture_path
	end
end
