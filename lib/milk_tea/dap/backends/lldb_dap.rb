# frozen_string_literal: true

require "open3"
require "thread"
require "timeout"

module MilkTea
  module DAP
    module Backends
      # Thin bridge to an lldb-dap compatible adapter process.
      class LLDBDAP
        def initialize(adapter_command: ["lldb-dap"], on_event: nil, on_request: nil)
          @adapter_command = adapter_command
          @on_event = on_event
          @on_request = on_request
          @protocol = nil
          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thread = nil
          @reader_thread = nil
          @stderr_thread = nil
          @write_mutex = Mutex.new
          @pending_mutex = Mutex.new
          @pending = {}
          @next_seq = 1
        end

        def start!
          return if running?

          @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(*@adapter_command)
          @protocol = Protocol.new(input: @stdout, output: @stdin)

          @reader_thread = Thread.new { read_loop }
          @stderr_thread = Thread.new { drain_stderr }
        end

        def running?
          !@wait_thread.nil? && @wait_thread.alive?
        end

        def request(command, arguments = {}, timeout: 5)
          start! unless running?

          seq = next_seq
          queue = Queue.new
          @pending_mutex.synchronize do
            @pending[seq] = queue
          end

          @write_mutex.synchronize do
            @protocol.write_message({
              seq: seq,
              type: "request",
              command: command,
              arguments: arguments
            })
          end

          Timeout.timeout(timeout) { queue.pop }
        rescue Timeout::Error
          {
            "type" => "response",
            "request_seq" => seq,
            "success" => false,
            "message" => "backend request timed out: #{command}"
          }
        ensure
          @pending_mutex.synchronize { @pending.delete(seq) }
        end

        def stop!
          @stdin&.close
          @stdout&.close
          @stderr&.close
          if @wait_thread&.alive?
            Process.kill("TERM", @wait_thread.pid)
          end
        rescue StandardError
          nil
        ensure
          @wait_thread&.join(0.2)
          @reader_thread&.join(0.2)
          @stderr_thread&.join(0.2)
          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thread = nil
          @reader_thread = nil
          @stderr_thread = nil
        end

        private

        def next_seq
          seq = @next_seq
          @next_seq += 1
          seq
        end

        def read_loop
          loop do
            message = @protocol.read_message
            break if message.nil?

            if message["type"] == "response"
              queue = @pending_mutex.synchronize { @pending[message["request_seq"]] }
              queue&.push(message)
            elsif message["type"] == "event"
              @on_event&.call(message)
            elsif message["type"] == "request"
              handle_adapter_request(message)
            end
          end
        rescue StandardError
          nil
        ensure
          @pending_mutex.synchronize do
            @pending.each_value do |queue|
              queue.push({
                "type" => "response",
                "success" => false,
                "message" => "backend closed"
              })
            end
            @pending.clear
          end
        end

        def drain_stderr
          return unless @stderr

          @stderr.each_line do |_line|
            # Intentionally ignored in this bridge layer.
          end
        rescue StandardError
          nil
        end

        def handle_adapter_request(message)
          response = @on_request&.call(message)
          response ||= {
            "type" => "response",
            "request_seq" => message["seq"],
            "success" => false,
            "command" => message["command"],
            "message" => "unsupported reverse request: #{message['command']}"
          }

          @write_mutex.synchronize do
            @protocol.write_message(response)
          end
        end
      end
    end
  end
end
