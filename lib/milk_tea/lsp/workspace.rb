# frozen_string_literal: true

require 'cgi/escape'
require 'set'
require 'thread'
require 'uri'

require_relative 'workspace/store'
require_relative 'workspace/caches'
require_relative 'workspace/analysis'
require_relative 'workspace/dependency_graph'
require_relative 'workspace/definition_index'
require_relative 'workspace/collection'
require_relative 'workspace/utilities'

module MilkTea
  module LSP
    # Manages open documents, AST cache, token cache, semantic facts cache, and symbol index.
    # Supports incremental document edits and workspace-wide indexing.
    class Workspace
      DOCUMENT_SOURCES = %w[active-editor visible-editor background-document].freeze
      PERF_LOG_THRESHOLD_MS = 1000

      # Token types that introduce a named definition, in order of precedence.
      #
      # NOTE: this list is intentionally minimal. Multi-keyword prefixes such as
      # 'const function', 'async function', 'external function', 'foreign function',
      # and visibility modifiers ('public') are captured by the adjacent-token scan
      # in extract_symbols_from_tokens because the scan relies on every pair of
      # adjacent tokens, and the inner keyword (e.g. :function) is always followed
      # by the identifier. If the lexer ever merges a compound keyword into a
      # single token type (e.g. :const_function), it must be added here.
      DEFINITION_KEYWORDS = %i[function struct union enum flags variant type const var let extending opaque interface event].freeze
      DOC_COMMENT_PREFIX = '##'
      DOC_TAG_PATTERN = /\A\s*@([A-Za-z_][A-Za-z0-9_-]*)(?:\s+(.*))?\z/
      DEFINITION_LINE_PREFIX = /^(?:\s)*(?:(?:public|foreign|external)\s+)*(?:function|struct|union|enum|flags|variant|type|const|var|let|extending|opaque|interface|event)\s+/m
      DEFINITION_NAME_REGEX = /^\s*(?:(?:public|foreign|external)\s+)*(?:function|struct|union|enum|flags|variant|type|const|var|let|extending|opaque|interface|event)\s+([A-Za-z_][A-Za-z0-9_]*)\b/

      def initialize
        @workspace_root_path = nil
        @dependency_resolution_mode = :auto
        @platform_override = nil
        @strict_current_root_diagnostics_enabled = false
        @open_documents = {}   # uri -> content String from didOpen/didChange
        @indexed_documents = {} # uri -> content String loaded from disk index
        @document_sources = {} # uri -> source string from the editor client
        @document_state_mutex = Mutex.new
        @tokens_cache = {}   # uri -> [Token]
        @last_good_tokens_cache = {} # uri -> last known-good [Token]
        @ast_cache = {}      # uri -> AST::SourceFile (nil on parse failure)
        @facts_cache = {} # uri -> SemanticAnalyzer::Facts (projection of cached tooling snapshot facts)
        @tooling_snapshot_cache = {} # uri -> SemanticAnalyzer::ToolingSnapshot (facts may be nil on structural failure)
        @symbols_cache = {}  # uri -> [{name, kind, line, column}]
        @doc_comments_cache = {} # uri -> {"line:column" => structured_doc_comment_hash}
        @last_good_facts_cache = {} # uri -> last SemanticAnalyzer::Facts that succeeded
        @last_good_tooling_snapshot_cache = {} # uri -> last SemanticAnalyzer::ToolingSnapshot with facts that succeeded
        @document_module_names = {} # uri -> module name string (populated from last-good facts)
        @shared_module_cache = {}
        @facts_cache_mutex = Mutex.new
        @facts_generation = Hash.new(0)
        @facts_state_mutex = Mutex.new
        # Diagnostics cache: uri -> { content_hash:, diagnostics: }
        @diagnostics_cache = {}
        @dependency_module_name_by_uri = {}
        @dependency_imports_by_uri = {}
        @reverse_import_dependents = Hash.new { |hash, key| hash[key] = Set.new }
        @full_reverse_index_built = false
        @full_reverse_index_built = false
        # Definition index: name -> { uri:, token: } — built lazily from symbols cache.
        # Caches known matching definitions without forcing a full-workspace index
        # build on the first global lookup.
        @definition_index = {} # name -> [{ uri:, token: Token }]
        @definition_miss_cache = Set.new
        @definition_candidate_uris = Hash.new { |hash, key| hash[key] = Set.new }
        @definition_names_by_uri = {}
        @definition_cache_mutex = Mutex.new
        @definition_warmup_queue = Queue.new
        @definition_warmup_enqueued = Set.new
        @definition_warmup_thread = nil
        # Identifier index: name -> [{uri:, line:, col:}] — lazily populated from tokens
        @identifier_index = {}
        @identifier_index_mutex = Mutex.new
        @indexed_uris = Set.new
      end

      def reset
        @indexed_documents.clear
        @tokens_cache.clear
        @last_good_tokens_cache.clear
        @ast_cache.clear
        @facts_cache.clear
        @tooling_snapshot_cache.clear
        @symbols_cache.clear
        @doc_comments_cache.clear
        @last_good_facts_cache.clear
        @last_good_tooling_snapshot_cache.clear
        @document_module_names.clear
        @shared_module_cache.clear
        @definition_index.clear
        @identifier_index.clear
        @full_reverse_index_built = false
        @indexed_uris.clear
        @definition_miss_cache.clear
        @definition_candidate_uris.clear
        @definition_names_by_uri.clear
        @definition_warmup_enqueued.clear
        @dependency_module_name_by_uri.clear
        @dependency_imports_by_uri.clear
        @reverse_import_dependents.clear
        @diagnostics_cache.clear
        @facts_generation.clear
      end

      include WorkspaceStore
      include WorkspaceCaches
      include WorkspaceAnalysis
      include WorkspaceDependencyGraph
      include WorkspaceDefinitionIndex
      include WorkspaceCollection
      include WorkspaceUtilities
    end
  end
end
