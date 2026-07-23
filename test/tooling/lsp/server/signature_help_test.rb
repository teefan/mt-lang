# frozen_string_literal: true

require_relative "helpers"

class SignatureHelpTest < Minitest::Test
  include LSPServerTestHelpers

  def test_signature_help_returns_function_signature_at_call_site
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_sighel_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      # Cursor right after "add(" on line 4: "    return add(" = 15 chars
      response = client.send_request("textDocument/signatureHelp", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 15 }
      })
      result = response.fetch("result")
      assert_equal 0, result["activeSignature"]
      assert_equal 0, result["activeParameter"]
      sig_label = result.dig("signatures", 0, "label")
      assert_includes sig_label, "add"
      assert_includes sig_label, "a: int"
      assert_includes sig_label, "b: int"
    end
  end

  def test_signature_help_tracks_active_parameter_by_comma_count
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_sighel2_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      # Cursor after "add(1, " on line 4: "    return add(1, " = 18 chars
      response = client.send_request("textDocument/signatureHelp", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 18 }
      })
      result = response.fetch("result")
      assert_equal 1, result["activeParameter"]
    end
  end

  def test_signature_help_includes_doc_comment_and_parameter_docs
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_sighel_structured_docs_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_STRUCTURED_DOC_TAGS }
      })

      response = client.send_request("textDocument/signatureHelp", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 9, "character" => 15 }
      })

      result = response.fetch("result")
      signature = result.dig("signatures", 0)
      signature_docs = signature.dig("documentation", "value")
      first_param_docs = signature.dig("parameters", 0, "documentation", "value")
      second_param_docs = signature.dig("parameters", 1, "documentation", "value")

      assert_includes signature_docs, "Adds two values."
      assert_includes signature_docs, "**Returns**"
      assert_includes signature_docs, "sum of both values"
      assert_equal "first addend", first_param_docs
      assert_equal "second addend", second_param_docs
    end
  end

end
