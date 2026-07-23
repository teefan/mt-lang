# frozen_string_literal: true

require "fileutils"
require "open3"
require "yaml"

module MilkTea
  module UpstreamSources
    class Error < StandardError; end

    Result = Data.define(:source, :status, :path)

    CONFIG_DIR = "config"
    REVISIONS_FILE = "upstream_versions.yml"

    Source = Data.define(:name, :checkout_root, :repository_url, :revision, :sentinel_paths) do
      def bootstrap!
        return Result.new(source: self, status: :present, path: checkout_root.to_s) if complete?

        FileUtils.rm_rf(checkout_root) if File.exist?(checkout_root)
        FileUtils.mkdir_p(checkout_root.dirname)

        run_git!("clone", repository_url, checkout_root.to_s)
        run_git!("-C", checkout_root.to_s, "checkout", "--detach", revision)

        unless complete?
          raise Error, "bootstrapped #{name} but required files are still missing under #{checkout_root}"
        end

        Result.new(source: self, status: :bootstrapped, path: checkout_root.to_s)
      end

      def complete?
        return false unless File.directory?(checkout_root)

        sentinel_paths.all? do |relative_path|
          File.exist?(checkout_root.join(relative_path))
        end
      end

      private

      def run_git!(*args)
        stdout, stderr, status = Open3.capture3("git", *args)
        return if status.success?

        details = [stdout, stderr].reject(&:empty?).join
        raise Error, details.empty? ? "failed to bootstrap #{name}" : "failed to bootstrap #{name}:\n#{details}"
      rescue Errno::ENOENT => e
        raise Error, "git not found while bootstrapping #{name}: #{e.message}"
      end
    end

    module_function

    def revisions_path(root: MilkTea.root)
      Pathname.new(File.expand_path(root.to_s)).join(CONFIG_DIR, REVISIONS_FILE)
    end

    def load_version_overrides(root: MilkTea.root)
      path = revisions_path(root:)
      return {} unless File.file?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [String]) || {}
      return {} unless data.is_a?(Hash)

      overrides = {}
      data.each do |name, entry|
        next unless name.is_a?(String)

        revision = if entry.is_a?(String)
                     entry
        elsif entry.is_a?(Hash)
                     entry["revision"] || entry[:revision] if entry["revision"] || entry[:revision]
        end
        overrides[name] = revision if revision.is_a?(String) && !revision.empty?
      end
      overrides
    end

    def load_sentinel_overrides(root: MilkTea.root)
      path = revisions_path(root:)
      return {} unless File.file?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [String, Array]) || {}
      return {} unless data.is_a?(Hash)

      overrides = {}
      data.each do |name, entry|
        next unless name.is_a?(String) && entry.is_a?(Hash)

        sentinels = entry["sentinels"] || entry[:sentinels]
        overrides[name] = sentinels if sentinels.is_a?(Array) && sentinels.all?(String)
      end
      overrides
    end

    def write_version_override(name, revision, root: MilkTea.root)
      path = revisions_path(root:)
      data = File.file?(path) ? (YAML.safe_load(File.read(path)) || {}) : {}
      existing = data[name.to_s]
      if existing.is_a?(Hash)
        existing["revision"] = revision.to_s
      else
        data[name.to_s] = revision.to_s
      end
      FileUtils.mkdir_p(path.dirname)
      File.write(path, data.to_yaml)
    end

    def remove_version_override(name, root: MilkTea.root)
      path = revisions_path(root:)
      return unless File.file?(path)

      data = YAML.safe_load(File.read(path)) || {}
      data.delete(name.to_s)
      if data.empty?
        FileUtils.rm_f(path)
      else
        File.write(path, data.to_yaml)
      end
    end

    def resolve_ref(repository_url, ref)
      return ref if ref.match?(/\A[0-9a-f]{40}\z/i)

      output, status = Open3.capture2("git", "ls-remote", "--refs", repository_url, ref.to_s)
      raise Error, "failed to resolve #{ref.inspect} for #{repository_url}" unless status.success?

      lines = output.lines.map(&:strip).reject(&:empty?)
      raise Error, "no ref found for #{ref.inspect} in #{repository_url}" if lines.empty?

      lines.each do |line|
        hash, full_name = line.split(/\s+/, 2)
        next unless full_name

        return hash if full_name == ref || full_name == "refs/tags/#{ref}" || full_name == "refs/heads/#{ref}"
      end

      lines.first.split(/\s+/, 2).first
    end

    def find_source(name, root: MilkTea.root)
      default_sources(root:).find { |source| source.name == name.to_s }
    end

    def default_sources(root: MilkTea.root)
      data = MilkTea.writable_root_for(root)
      sources = [
        Source.new(
          name: "raylib",
          checkout_root: data.join("third_party/raylib-upstream"),
          repository_url: "https://github.com/raysan5/raylib.git",
          revision: "dbc56a87da87d973a9c5baa4e7438a9d20121d28",
          sentinel_paths: %w[
            src/raylib.h
            examples/shapes/raygui.h
            examples/core/msf_gif.h
          ],
        ),
        Source.new(
          name: "sdl3",
          checkout_root: data.join("third_party/sdl3-upstream"),
          repository_url: "https://github.com/libsdl-org/SDL.git",
          revision: "41f079491a0e79b22441fd32a7c8ad91db237744",
          sentinel_paths: %w[
            CMakeLists.txt
            include/SDL3/SDL.h
            include/SDL3/SDL_main.h
          ],
        ),
        Source.new(
          name: "glfw",
          checkout_root: data.join("third_party/glfw-upstream"),
          repository_url: "https://github.com/glfw/glfw.git",
          revision: "b00e6a8a88ad1b60c0a045e696301deb92c9a13e",
          sentinel_paths: %w[
            include/GLFW/glfw3.h
            include/GLFW/glfw3native.h
          ],
        ),
        Source.new(
          name: "opengl_registry",
          checkout_root: data.join("third_party/opengl-registry-upstream"),
          repository_url: "https://github.com/KhronosGroup/OpenGL-Registry.git",
          revision: "9cb90ca4902d588bef3c830fbb1da484893bd5fb",
          sentinel_paths: %w[
            xml/gl.xml
            xml/glx.xml
            xml/wgl.xml
          ],
        ),
        Source.new(
          name: "box2d",
          checkout_root: data.join("third_party/box2d-upstream"),
          repository_url: "https://github.com/erincatto/box2d.git",
          revision: "ddfd9df727a06940af34b5bc2ef79bcaba287d50",
          sentinel_paths: %w[
            include/box2d/box2d.h
          ],
        ),
        Source.new(
          name: "cjson",
          checkout_root: data.join("third_party/cjson-upstream"),
          repository_url: "https://github.com/DaveGamble/cJSON.git",
          revision: "c859b25da02955fef659d658b8f324b5cde87be3",
          sentinel_paths: %w[
            cJSON.h
            cJSON.c
          ],
        ),
        Source.new(
          name: "flecs",
          checkout_root: data.join("third_party/flecs-upstream"),
          repository_url: "https://github.com/SanderMertens/flecs.git",
          revision: "d7d0c4f7afb4518a6bae749efdc52c7cb5cffee6",
          sentinel_paths: %w[
            distr/flecs.c
            distr/flecs.h
            include/flecs.h
          ],
        ),
        Source.new(
          name: "libuv",
          checkout_root: data.join("third_party/libuv-upstream"),
          repository_url: "https://github.com/libuv/libuv.git",
          revision: "1cfa32ff59c076ffb6ed735bbc8c18361558661f",
          sentinel_paths: %w[
            CMakeLists.txt
            include/uv.h
            include/uv/version.h
          ],
        ),
        Source.new(
          name: "pcre2",
          checkout_root: data.join("third_party/pcre2-upstream"),
          repository_url: "https://github.com/PCRE2Project/pcre2.git",
          revision: "b2bd4254b379b9d7dc9a3dda060a7e27009ccdff",
          sentinel_paths: %w[
            CMakeLists.txt
            src/pcre2.h.generic
            src/pcre2_compile.c
          ],
        ),
        Source.new(
          name: "steamworks_sdk",
          checkout_root: data.join("third_party/steamworks-sdk-upstream"),
          repository_url: "https://github.com/rlabrecque/steamworkssdk.git",
          revision: "be6107f4b75bf996531415c53a6488a33a2a1be3",
          sentinel_paths: %w[
            public/steam/steam_api.h
            public/steam/steam_api_common.h
            public/steam/steam_api_internal.h
            public/steam/steam_api_flat.h
            public/steam/steam_api.json
            public/steam/steam_gameserver.h
          ],
        ),
        Source.new(
          name: "miniaudio",
          checkout_root: data.join("third_party/miniaudio-upstream"),
          repository_url: "https://github.com/mackron/miniaudio.git",
          revision: "9634bedb5b5a2ca38c1ee7108a9358a4e233f14d",
          sentinel_paths: %w[
            miniaudio.h
          ],
        ),
        Source.new(
          name: "tracy",
          checkout_root: data.join("third_party/tracy-upstream"),
          repository_url: "https://github.com/wolfpld/tracy.git",
          revision: "v0.13.1",
          sentinel_paths: %w[
            public/tracy/TracyC.h
          ],
        ),
        Source.new(
          name: "raygui",
          checkout_root: data.join("third_party/raygui-upstream"),
          repository_url: "https://github.com/raysan5/raygui.git",
          revision: "5.0",
          sentinel_paths: %w[
            src/raygui.h
          ],
        ),
        Source.new(
          name: "rres",
          checkout_root: data.join("third_party/rres-upstream"),
          repository_url: "https://github.com/raysan5/rres.git",
          revision: "5f2a7310197f8b7843ab5b024277a14da83f68f9",
          sentinel_paths: %w[
            src/rres.h
          ],
        ),
        Source.new(
          name: "rpng",
          checkout_root: data.join("third_party/rpng-upstream"),
          repository_url: "https://github.com/raysan5/rpng.git",
          revision: "b8c05ae4e9d7535f8bceac9ea365211ae7401cee",
          sentinel_paths: %w[
            src/rpng.h
          ],
        ),
        Source.new(
          name: "stb",
          checkout_root: data.join("third_party/stb-upstream"),
          repository_url: "https://github.com/nothings/stb.git",
          revision: "31c1ad37456438565541f4919958214b6e762fb4",
          sentinel_paths: %w[
            stb_image.h
            stb_truetype.h
          ],
        ),
        Source.new(
          name: "cgltf",
          checkout_root: data.join("third_party/cgltf-upstream"),
          repository_url: "https://github.com/jkuhlmann/cgltf.git",
          revision: "85cd62382dfea638278962690cf515023f33ed00",
          sentinel_paths: %w[
            cgltf.h
          ],
        ),
      ]

      version_overrides = load_version_overrides(root:)
      sentinel_overrides = load_sentinel_overrides(root:)

      unless version_overrides.empty? && sentinel_overrides.empty?
        sources = sources.map do |source|
          new_rev = version_overrides[source.name]
          new_sentinels = sentinel_overrides[source.name]
          source = source.with(revision: new_rev) if new_rev
          source = source.with(sentinel_paths: new_sentinels) if new_sentinels
          source
        end
      end

      sources
    end

    def bootstrap_all!(root: MilkTea.root)
      default_sources(root:).map(&:bootstrap!)
    end

    def bootstrap_one(name, root: MilkTea.root)
      source = find_source(name, root:)
      raise Error, "unknown upstream source: #{name}" unless source

      source.bootstrap!
    end
  end
end
