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

      # Token types that introduce a named definition, in order of precedence
      DEFINITION_KEYWORDS = %i[function struct union enum flags variant type const var let extending opaque interface event].freeze
      DOC_COMMENT_PREFIX = '##'
      DOC_TAG_PATTERN = /\A\s*@([A-Za-z_][A-Za-z0-9_-]*)(?:\s+(.*))?\z/
      DEFINITION_LINE_PREFIX = /^(?:\s)*(?:(?:public|foreign|external)\s+)*(?:function|struct|union|enum|flags|variant|type|const|var|let|extending|opaque|interface|event)\s+/m
      DEFINITION_NAME_REGEX = /^\s*(?:(?:public|foreign|external)\s+)*(?:function|struct|union|enum|flags|variant|type|const|var|let|extending|opaque|interface|event)\s+([A-Za-z_][A-Za-z0-9_]*)\b/

      def initialize(error_output: nil)
        @error_output = error_output
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
        @facts_cache = {} # uri -> Sema::Facts (projection of cached tooling snapshot facts)
        @tooling_snapshot_cache = {} # uri -> Sema::ToolingSnapshot (facts may be nil on structural failure)
        @symbols_cache = {}  # uri -> [{name, kind, line, column}]
        @doc_comments_cache = {} # uri -> {"line:column" => structured_doc_comment_hash}
        @last_good_facts_cache = {} # uri -> last Sema::Facts that succeeded
        @last_good_tooling_snapshot_cache = {} # uri -> last Sema::ToolingSnapshot with facts that succeeded
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
