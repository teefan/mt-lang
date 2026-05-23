# frozen_string_literal: true

require "cgi/escape"
require "minitest/autorun"
require "socket"
require_relative "../lib/milk_tea"

if defined?(Minitest::CoverageRunner) && !Minitest::CoverageRunner.method_defined?(:find_path_and_lines_without_milk_tea_mapping)
	module Minitest
		module CoverageRunner
			alias_method :find_path_and_lines_without_milk_tea_mapping, :find_path_and_lines

			def find_path_and_lines(coverage, test_name)
				milk_tea_coverage_candidate_paths.each do |candidate|
					lines = coverage[candidate]
					return [candidate, lines] if lines
				end

				find_path_and_lines_without_milk_tea_mapping(coverage, test_name)
			end

			def milk_tea_coverage_candidate_paths
				cached = self.instance_variable_get(:@milk_tea_coverage_candidate_paths)
				return cached if cached

				test_file = runnable_methods.lazy.map do |method_name|
					instance_method(method_name).source_location&.first
				rescue NameError
					nil
				end.find { |path| path && path.start_with?(PWD) }

				candidates = []
				if test_file
					relative_test_path = test_file.delete_prefix(PWD + File::SEPARATOR)
					relative_impl_path = relative_test_path.sub(/\Atest\//, "").sub(/_test\.rb\z/, ".rb")
					relative_impl_path = case relative_impl_path
					when /\Acompiler\//
						relative_impl_path.sub(/\Acompiler\//, "core/")
					when /\Atooling\/lsp\//
						relative_impl_path.sub(/\Atooling\/lsp\//, "lsp/")
					when /\Atooling\/dap\//
						relative_impl_path.sub(/\Atooling\/dap\//, "dap/")
					when /\Atooling\/entrypoint\.rb\z/
						"milk_tea.rb"
					when /\Atooling\//, /\Abindings\//, /\Apackages\//
						relative_impl_path
					else
						nil
					end

					if relative_impl_path
						base_path = relative_impl_path == "milk_tea.rb" ? relative_impl_path : File.join("milk_tea", relative_impl_path)
						candidates << File.join(PWD, "lib", base_path)
					end
				end

				candidates << File.join(PWD, "lib", impl_name(self.name))
				candidates = candidates.uniq.freeze
				self.instance_variable_set(:@milk_tea_coverage_candidate_paths, candidates)
			end
		end
	end
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

	def with_singleton_method_override(object, method_name, implementation)
		singleton_class = class << object; self; end
		original_name = "__test_helper_original_#{method_name}__"
		original_defined = singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
		singleton_class.alias_method(original_name, method_name) if original_defined
		singleton_class.define_method(method_name) do |*args, **kwargs, &block|
			implementation.call(*args, **kwargs, &block)
		end
		yield
	ensure
		singleton_class.remove_method(method_name) if singleton_class.method_defined?(method_name)
		if original_defined
			singleton_class.alias_method(method_name, original_name)
			singleton_class.remove_method(original_name)
		end
	end
end
