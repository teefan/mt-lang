# frozen_string_literal: true

require "sinatra/base"
require "json"
require "open3"

module MilkTea
  class DocsApp < Sinatra::Base
    SNAPSHOT_CACHE = {}

    MODULE_CATEGORIES = {
      "Collections" => %w[vec deque binary_heap priority_queue ordered_set ordered_map map set linked_map linked_set counter multiset queue stack],
      "Memory" => %w[mem cell],
      "Text & Format" => %w[string str fmt cstring encoding base64],
      "Math & Random" => %w[math random],
      "Data & Serialization" => %w[binary bytes json toml tar gzip zstd crypto hash],
      "Concurrency" => %w[async jobs sync thread],
      "Files & I/O" => %w[fs path stdio],
      "System" => %w[ctype errno process time c],
      "Network & HTTP" => %w[net http uri cookie curl],
      "Game & Graphics" => %w[raylib box2d flecs enet cgltf cjson],
      "Algorithms & AI" => %w[fsm behavior_tree goap],
      "Database & Matching" => %w[sqlite3 pcre2],
      "Utilities" => %w[cli terminal span spatial asset_pack],
    }.freeze

    configure do
      set :views, File.expand_path("views", __dir__)
      set :public_folder, File.expand_path("public", __dir__)
      set :static, true
      set :logging, false
      set :show_exceptions, false
    end

    helpers do
      def stdlib_root
        @stdlib_root ||= File.expand_path("../../../std", __dir__)
      end

      def reference_index
        @reference_index ||= File.expand_path("../../../docs/reference/index.html", __dir__)
      end

      def h(text)
        Rack::Utils.escape_html(text.to_s)
      end

      def active?(path)
        request.path_info == path ? "active" : ""
      end

      def stdlib_modules
        @stdlib_modules ||= discover_modules.freeze
      end

      def categorized_modules
        @categorized_modules ||= begin
          cats = {}
          uncategorized = []

          stdlib_modules.each do |mod|
            cat = MODULE_CATEGORIES.find { |_, names| names.include?(mod[:name]) }&.first
            if cat
              (cats[cat] ||= []) << mod
            else
              uncategorized << mod
            end
          end

          cats["Other"] = uncategorized unless uncategorized.empty?
          cats
        end.freeze
      end

      def snapshot_available?
        !!snapshot_script_path
      end

      def snapshot_for(source_path)
        return nil unless snapshot_available?

        cache_key = "#{source_path}:#{File.mtime(source_path).to_i}"
        cached = SNAPSHOT_CACHE[cache_key]
        return cached if cached

        html = run_snapshot(source_path)
        SNAPSHOT_CACHE[cache_key] = html if html
        html
      end

      private

      def snapshot_script_path
        return @snapshot_script_path if defined?(@snapshot_script_path)

        candidate = File.expand_path("../../../bindings/vscode/scripts/snapshot.js", __dir__)
        @snapshot_script_path = File.file?(candidate) ? candidate : nil
      end

      def snapshot_theme_path
        return @snapshot_theme_path if defined?(@snapshot_theme_path)

        candidate = File.expand_path("../../../bindings/vscode/themes/2026-dark.json", __dir__)
        @snapshot_theme_path = File.file?(candidate) ? candidate : nil
      end

      def run_snapshot(source_path)
        script = snapshot_script_path
        theme = snapshot_theme_path
        return nil unless script && theme

        stdout, stderr, status = Open3.capture3("node", script, source_path, "-t", theme)

        unless status.success?
          warn("snapshot failed for #{source_path}: #{stderr}")
          return nil
        end

        stdout
      end

      private

      def discover_modules
        mods = []
        root = stdlib_root
        return mods unless File.directory?(root)

        dir_names = Dir.glob(File.join(root, "*")).filter_map do |entry|
          next unless File.directory?(entry)
          name = File.basename(entry)
          mts = Dir.glob(File.join(entry, "*.mt"))
          next if mts.empty?
          mods << { name:, path: entry, kind: :dir }
          name
        end

        Dir.glob(File.join(root, "*.mt")).sort.each do |file|
          name = File.basename(file, ".mt")
          next if name.end_with?(".linux", ".windows", ".wasm")
          next if dir_names.include?(name)
          mods << { name:, path: file, kind: :file }
        end

        mods
      end

      def extract_doc_comment(source)
        lines = source.lines
        doc_lines = []
        in_doc = false

        lines.each do |line|
          if line.start_with?("##")
            doc_lines << line.sub(/^## ?/, "").rstrip
            in_doc = true
          elsif in_doc && line.strip.empty?
            break
          elsif in_doc
            break
          end
        end

        doc_lines.join("\n").strip
      end

      def extract_declarations(source)
        decls = []
        extend_parent = nil
        extend_indent = nil
        doc_lines = []

        source.each_line do |line|
          stripped = line.strip
          indent = line[/\A */].length

          if stripped.start_with?("##")
            doc_lines << stripped.sub(/^## ?/, "").rstrip
            next
          end

          next if stripped.empty? || stripped.start_with?("#") || stripped.start_with?("import")

          if extend_parent && indent <= extend_indent
            extend_parent = nil
            extend_indent = nil
          end

          kind, name = classify_declaration(stripped)

          unless kind && name
            doc_lines = []
            next
          end

          if kind == "extend"
            extend_parent = name
            extend_indent = indent
            next
          end

          doc = doc_lines.empty? ? nil : doc_lines.join("\n")
          doc_lines = []

          if extend_parent && indent > extend_indent
            decls << { kind:, name:, line: stripped, parent: extend_parent, doc: }
          else
            decls << { kind:, name:, line: stripped, doc: }
          end
        end
        decls
      end

      def classify_declaration(stripped)
        case stripped
        when /\A(public\s+)?(?:(?:external|foreign|async|const|static|editable)\s+)*function\s+(\w+)/
          ["func", $2]
        when /\A(public\s+)?const\s+(\w+)/
          ["const", $2]
        when /\A(public\s+)?struct\s+(\w+)/
          ["struct", $2]
        when /\A(public\s+)?enum\s+(\w+)/
          ["enum", $2]
        when /\A(public\s+)?flags\s+(\w+)/
          ["flags", $2]
        when /\A(public\s+)?variant\s+(\w+)/
          ["variant", $2]
        when /\A(public\s+)?union\s+(\w+)/
          ["union", $2]
        when /\A(public\s+)?opaque\s+(\w+)/
          ["opaque", $2]
        when /\A(public\s+)?type\s+(\w+)/
          ["type", $2]
        when /\A(public\s+)?interface\s+(\w+)/
          ["interface", $2]
        when /\A(public\s+)?event\s+(\w+)/
          ["event", $2]
        when /\Aextending\s+([^\[:\s]+)/
          ["extend", $1]
        when /\A(public\s+)?attribute\[/
          ["attr", stripped[/attribute\[.*?\]\s+(\w+)/, 1]]
        end
      end

      def read_module_source(path)
        File.read(path)
      rescue Errno::ENOENT
        nil
      end

      def module_files(mod)
        if mod[:kind] == :dir
          Dir.glob(File.join(mod[:path], "*.mt")).sort.filter_map do |f|
            basename = File.basename(f, ".mt")
            next if basename.end_with?(".linux", ".windows", ".wasm")
            { name: basename, path: f }
          end
        else
          [{ name: mod[:name], path: mod[:path] }]
        end
      end

      def resolve_source_path(mod, file_name)
        if mod[:kind] == :dir
          candidate = File.join(mod[:path], "#{file_name}.mt")
          File.file?(candidate) ? candidate : nil
        elsif file_name == mod[:name]
          mod[:path]
        end
      end
    end

    # ---- Routes ----

    get "/" do
      content_type :html
      File.read(reference_index)
    end

    get "/reference" do
      redirect "/reference/"
    end

    get "/reference/" do
      content_type :html
      File.read(reference_index)
    end

    get "/stdlib" do
      @breadcrumbs = [["Reference", "/"], ["Standard Library", nil]]
      @modules = stdlib_modules.map do |mod|
        primary = if mod[:kind] == :dir
          File.join(mod[:path], "#{mod[:name]}.mt")
        else
          mod[:path]
        end
        source = read_module_source(primary)
        doc = source ? extract_doc_comment(source) : ""
        decl_count = source ? extract_declarations(source).size : 0
        mod.merge(doc:, decl_count:)
      end
      erb :stdlib
    end

    get "/stdlib/:name" do
      @name = params[:name]
      mod = stdlib_modules.find { |m| m[:name] == @name }
      halt 404 unless mod

      @breadcrumbs = [["Reference", "/"], ["Standard Library", "/stdlib"], [@name, nil]]
      @mod = mod
      @files = module_files(mod).filter_map do |f|
        source = read_module_source(f[:path])
        next unless source
        { name: f[:name], doc: extract_doc_comment(source), decls: extract_declarations(source) }
      end

      erb :module
    end

    get "/stdlib/:name/source/:file" do
      mod = stdlib_modules.find { |m| m[:name] == params[:name] }
      halt 404 unless mod

      file_path = resolve_source_path(mod, params[:file])
      halt 404 unless file_path && File.file?(file_path)
      content_type "text/plain"
      File.read(file_path)
    end

    get "/stdlib/:name/source/:file/hl" do
      mod = stdlib_modules.find { |m| m[:name] == params[:name] }
      halt 404 unless mod

      file_path = resolve_source_path(mod, params[:file])
      halt 404 unless file_path && File.file?(file_path)

      html = snapshot_for(file_path)
      unless html
        content_type "text/plain"
        halt 503, "Syntax highlighting unavailable (node.js or snapshot dependencies not found)"
      end

      content_type :html
      html
    end

    get "/api/search" do
      content_type :json
      query = (params[:q] || "").downcase.strip
      return "[]" if query.empty? || query.length < 2

      results = stdlib_modules.filter_map do |mod|
        next unless mod[:name].downcase.include?(query)

        primary = mod[:kind] == :dir ? File.join(mod[:path], "#{mod[:name]}.mt") : mod[:path]
        source = read_module_source(primary)
        doc_line = source ? extract_doc_comment(source).lines.first&.strip : nil

        { name: mod[:name], kind: mod[:kind].to_s, summary: doc_line }
      end
      results.to_json
    end

    error 404 do
      erb :"404"
    end
  end
end
