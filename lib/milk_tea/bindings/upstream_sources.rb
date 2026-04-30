# frozen_string_literal: true

require "fileutils"
require "open3"

module MilkTea
  module UpstreamSources
    class Error < StandardError; end

    Result = Data.define(:source, :status, :path)

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

    def default_sources(root: MilkTea.root)
      [
        Source.new(
          name: "raylib",
          checkout_root: root.join("third_party/raylib-upstream"),
          repository_url: "https://github.com/raysan5/raylib.git",
          revision: "dbc56a87da87d973a9c5baa4e7438a9d20121d28",
          sentinel_paths: %w[
            src/raylib.h
            examples/shapes/raygui.h
            examples/shaders/rlights.h
            examples/core/msf_gif.h
          ],
        ),
        Source.new(
          name: "sdl3",
          checkout_root: root.join("third_party/sdl3-upstream"),
          repository_url: "https://github.com/libsdl-org/SDL.git",
          revision: "41f079491a0e79b22441fd32a7c8ad91db237744",
          sentinel_paths: %w[
            include/SDL3/SDL.h
            include/SDL3/SDL_main.h
          ],
        ),
        Source.new(
          name: "box2d",
          checkout_root: root.join("third_party/box2d-upstream"),
          repository_url: "https://github.com/erincatto/box2d.git",
          revision: "ddfd9df727a06940af34b5bc2ef79bcaba287d50",
          sentinel_paths: %w[
            include/box2d/box2d.h
          ],
        ),
        Source.new(
          name: "cjson",
          checkout_root: root.join("third_party/cjson-upstream"),
          repository_url: "https://github.com/DaveGamble/cJSON.git",
          revision: "c859b25da02955fef659d658b8f324b5cde87be3",
          sentinel_paths: %w[
            cJSON.h
            cJSON.c
          ],
        ),
      ]
    end

    def bootstrap_all!(root: MilkTea.root)
      default_sources(root:).map(&:bootstrap!)
    end
  end
end
