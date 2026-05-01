# frozen_string_literal: true

module MilkTea
  module LSP
    # LSP implementation - language server protocol support
  end
end

require_relative 'lsp/protocol'
require_relative 'lsp/workspace'
require_relative 'lsp/diagnostics'
require_relative 'lsp/server'
