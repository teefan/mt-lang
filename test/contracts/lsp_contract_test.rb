# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "timeout"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaLspContractTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("lsp_fixtures", __dir__)
  DEFAULT_SERVER_COMMAND = [RbConfig.ruby, File.expand_path("../../bin/mtc-lsp", __dir__)].freeze
  CONTRACT_LSP_COMMAND_ENV = "MILK_TEA_CONTRACT_LSP_CMD"

  class LspClient
    def initialize(stdin_write, stdout_read)
      @stdin = stdin_write
      @stdout = stdout_read
      @next_id = 1
    end

    def send_request(method, params = {})
      id = @next_id
      @next_id += 1
      write_message({ jsonrpc: "2.0", id:, method:, params: })
      read_until_response(id)
    end

    def send_notification(method, params = {})
      write_message({ jsonrpc: "2.0", method:, params: })
    end

    private

    def write_message(message)
      json = JSON.dump(message)
      @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
      @stdin.flush
    end

    def read_until_response(expected_id, timeout: 5)
      Timeout.timeout(timeout) do
        loop do
          message = read_message
          return nil if message.nil?
          next unless message["id"] == expected_id

          return message
        end
      end
    end

    def read_message
      headers = {}
      loop do
        line = @stdout.gets
        return nil if line.nil?

        stripped = line.chomp.sub(/\r\z/, "")
        break if stripped.empty?

        key, value = stripped.split(":", 2)
        headers[key.strip] = value.strip
      end

      content_length = headers["Content-Length"]&.to_i
      return nil if content_length.nil? || content_length <= 0

      JSON.parse(@stdout.read(content_length))
    end
  end

  Dir.glob(File.join(FIXTURE_ROOT, "*", "case.json")).sort.each do |case_path|
    case_dir = File.dirname(case_path)
    case_name = JSON.parse(File.read(case_path)).fetch("name")

    define_method("test_lsp_contract_case_#{case_name}") do
      run_contract_case(case_dir, JSON.parse(File.read(case_path)))
    end
  end

  private

  def run_contract_case(case_dir, contract_case)
    Dir.mktmpdir("milk-tea-lsp-contract") do |sandbox|
      FileUtils.cp_r(File.join(case_dir, "."), sandbox)
      workdir = File.join(sandbox, contract_case.fetch("cwd", "."))
      stderr_output = +""

      Open3.popen3(*contract_lsp_command, chdir: workdir) do |stdin, stdout, stderr, wait_thr|
        stderr_reader = Thread.new { stderr.read.to_s }
        client = LspClient.new(stdin, stdout)

        root_path = File.join(workdir, contract_case.fetch("rootPath", "."))
        initialize_response = client.send_request("initialize", {
          "rootUri" => path_to_uri(root_path),
          "capabilities" => {},
        }.merge(contract_case.fetch("initialize", {})))
        client.send_notification("initialized", {})

        document_path = File.join(workdir, contract_case.fetch("documentPath"))
        document_uri = path_to_uri(document_path)
        document_text = File.read(document_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => document_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => document_text,
          }
        })

        response = client.send_request(
          contract_case.fetch("requestMethod"),
          request_params_for(contract_case.fetch("requestMethod"), document_uri, contract_case.fetch("requestParams", {}))
        )
        normalized_result = normalize_result(
          contract_case.fetch("requestMethod"),
          response.fetch("result"),
          initialize_response,
          workdir
        )

        expected_result = contract_case.fetch("result")
        expected_path = File.join(case_dir, expected_result.fetch("path"))
        compare_json_expectation(normalized_result, expected_result.fetch("type"), expected_path)

        client.send_request("shutdown", {})
        client.send_notification("exit")
        stdin.close
        status = wait_thr.value
        stderr_output = stderr_reader.value

        assert_equal contract_case.fetch("stderr", ""), stderr_output
        assert status.success?, "mtc-lsp exited with #{status.exitstatus.inspect}"
      rescue StandardError
        Process.kill("TERM", wait_thr.pid) if wait_thr&.alive?
        raise
      end
    end
  end

  def request_params_for(method, document_uri, override_params)
    base_params = case method
                  when "textDocument/diagnostic", "textDocument/semanticTokens/full", "textDocument/hover", "textDocument/definition"
                    { "textDocument" => { "uri" => document_uri } }
                  else
                    raise ArgumentError, "unsupported request method #{method.inspect}"
                  end

    merged_params = base_params.merge(override_params)
    if merged_params["textDocument"].is_a?(Hash)
      merged_params["textDocument"] = base_params.fetch("textDocument").merge(merged_params.fetch("textDocument"))
    end

    merged_params
  end

  def contract_lsp_command
    configured_command = ENV.fetch(CONTRACT_LSP_COMMAND_ENV, "").strip
    return DEFAULT_SERVER_COMMAND if configured_command.empty?

    command = Shellwords.split(configured_command)
    raise ArgumentError, "#{CONTRACT_LSP_COMMAND_ENV} must not be empty" if command.empty?

    command
  end

  def normalize_result(method, result, initialize_response, workdir)
    case method
    when "textDocument/diagnostic"
      result
    when "textDocument/semanticTokens/full"
      legend = initialize_response.dig("result", "capabilities", "semanticTokensProvider", "legend")
      {
        "entries" => decode_semantic_token_entries(result.fetch("data"), legend)
      }
    when "textDocument/hover"
      normalize_hover_result(result, workdir)
    when "textDocument/definition"
      normalize_definition_result(result, workdir)
    else
      result
    end
  end

  def normalize_hover_result(result, workdir)
    value = normalize_hover_markdown(result.dig("contents", "value").to_s, workdir)
    signature_lines, doc_lines, defined_at = parse_hover_markdown(value)

    {
      "signatureLines" => signature_lines,
      "docs" => doc_lines,
      "definedAt" => defined_at,
      "range" => {
        "line" => result.dig("range", "start", "line"),
        "startChar" => result.dig("range", "start", "character"),
        "endChar" => result.dig("range", "end", "character")
      }
    }
  end

  def normalize_definition_result(result, workdir)
    return nil if result.nil?

    if result.is_a?(Array)
      result.map { |location| normalize_location(location, workdir) }
    else
      normalize_location(result, workdir)
    end
  end

  def normalize_location(location, workdir)
    {
      "path" => contract_path_from_uri(location.fetch("uri"), workdir),
      "line" => location.dig("range", "start", "line"),
      "character" => location.dig("range", "start", "character")
    }
  end

  def compare_json_expectation(actual, type, expected_path)
    expected = JSON.parse(File.read(expected_path))
    case type
    when "json-exact"
      assert_equal expected, actual
    when "json-projection"
      assert_equal expected, projected_json(actual, expected)
    else
      flunk("unknown result expectation type #{type.inspect}")
    end
  end

  def projected_json(actual, expected)
    case expected
    when Hash
      expected.each_with_object({}) do |(key, value), memo|
        memo[key] = projected_json(actual.fetch(key), value)
      end
    when Array
      assert_operator actual.length, :>=, expected.length
      expected.each_with_index.map do |value, index|
        projected_json(actual.fetch(index), value)
      end
    else
      actual
    end
  end

  def path_to_uri(path)
    escaped_path = File.expand_path(path).tr("\\", "/").split("/").map { |segment| CGI.escape(segment).gsub("+", "%20") }.join("/")
    "file://#{escaped_path}"
  end

  def contract_path_from_uri(uri, workdir)
    absolute_path = absolute_path_from_uri(uri)
    base_path = File.expand_path(workdir)
    return "." if absolute_path == base_path
    return absolute_path.delete_prefix(base_path + "/") if absolute_path.start_with?(base_path + "/")

    absolute_path
  end

  def absolute_path_from_uri(uri)
    path_part = uri.sub(/\Afile:\/\//, "").split("#", 2).first
    decoded_path = path_part.split("/").map { |segment| CGI.unescape(segment) }.join("/")
    decoded_path.start_with?("/") ? decoded_path : "/#{decoded_path}"
  end

  def normalize_hover_markdown(value, workdir)
    value.gsub(/file:\/\/[^\s)]+/) do |uri|
      fragment = uri.split("#", 2)[1]
      normalized = "file://#{contract_path_from_uri(uri, workdir)}"
      fragment ? "#{normalized}##{fragment}" : normalized
    end
  end

  def parse_hover_markdown(value)
    signature_lines = []
    doc_lines = []
    defined_at = nil
    inside_code_block = false

    value.each_line(chomp: true) do |line|
      if line.start_with?("```")
        inside_code_block = !inside_code_block
        next
      end

      if inside_code_block
        signature_lines << line
        next
      end

      next if line.empty?

      if line.start_with?("Defined at: ")
        defined_at = line
      else
        doc_lines << line
      end
    end

    [signature_lines, doc_lines, defined_at]
  end

  def decode_semantic_token_entries(data, legend)
    line = 0
    char = 0

    data.each_slice(5).map do |delta_line, delta_start, length, token_type_idx, modifier_bits|
      line += delta_line
      char = delta_line.zero? ? char + delta_start : delta_start

      {
        "line" => line,
        "startChar" => char,
        "endChar" => char + length,
        "tokenType" => legend.fetch("tokenTypes").fetch(token_type_idx),
        "modifierNames" => legend.fetch("tokenModifiers").each_with_index.filter_map do |name, bit|
          name if (modifier_bits & (1 << bit)) != 0
        end
      }
    end
  end
end
