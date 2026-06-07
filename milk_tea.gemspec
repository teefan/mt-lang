# frozen_string_literal: true

require_relative "lib/milk_tea/base"

Gem::Specification.new do |spec|
  spec.name          = "milk_tea"
  spec.version       = MilkTea::VERSION
  spec.authors       = ["Milk Tea contributors"]
  spec.summary       = "The Milk Tea programming language compiler toolchain"
  spec.description   = "A statically-typed, compiled programming language with C ABI interop, " \
                        "async/await, generics, pattern matching, and a comprehensive standard library. " \
                        "Includes the mtc compiler, LSP language server, and DAP debug adapter."
  spec.homepage      = "https://github.com/teefan/mt-lang"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    gem_files = %w[
      LICENSE
      README.md
      Gemfile
      Gemfile.lock
      Rakefile
      .ruby-version
    ]
    gem_files += Dir.glob("lib/**/*.rb").to_a
    gem_files += Dir.glob("lib/**/*.html").to_a
    gem_files += Dir.glob("bin/*").to_a
    gem_files += Dir.glob("std/**/*").to_a
    gem_files += Dir.glob("bindings/imported/**/*").to_a
    gem_files
  end

  spec.executables = %w[mtc mtc-lsp mtc-dap].map { |name| File.basename(name) }
  spec.require_paths = %w[lib]

  spec.add_dependency "rake",     "~> 13.4"
  spec.add_dependency "rexml",    "~> 3.4"
  spec.add_dependency "fiddle"
  spec.add_dependency "racc",     "~> 1.8"
  spec.add_dependency "tomlrb",   "~> 2.0", ">= 2.0.4"

  spec.post_install_message = <<~MSG
    Milk Tea #{MilkTea::VERSION} installed!

    System requirements:
      - A C compiler (gcc or clang) must be available on PATH
      - Optional: cmake + ninja for vendored C libraries (SDL3, GLFW, etc.)
      - Optional: git for bootstrapping vendored library sources on first use

    Get started: mtc run hello.mt
  MSG
end
