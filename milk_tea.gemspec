# frozen_string_literal: true

require_relative "lib/milk_tea/base"

Gem::Specification.new do |spec|
  spec.name          = "mt-lang"
  spec.version       = MilkTea::VERSION
  spec.authors       = ["Long (Teefan) Tran"]
  spec.summary       = "The Milk Tea programming language compiler toolchain"
  spec.description   = "A statically-typed, compiled programming language with C ABI interop, " \
                        "async/await, generics, pattern matching, and a comprehensive standard library. " \
                        "Includes the mtc compiler, LSP server (mtc lsp), and DAP debug adapter (mtc dap)."
  spec.homepage      = "https://teefan.github.io/mt-lang/"
  spec.license       = "MIT"
  spec.licenses      = ["MIT"]
  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/teefan/mt-lang"

  spec.files = Dir.chdir(__dir__) do
    gem_files = %w[
      AUTHORS
      LICENSE
      README.md
      Gemfile
      Gemfile.lock
      Rakefile
      .ruby-version
    ]
    gem_files += Dir.glob("lib/**/*.rb").to_a
    gem_files += Dir.glob("lib/**/*.html").to_a
    gem_files += Dir.glob("lib/**/*.erb").to_a
    gem_files += Dir.glob("lib/**/public/**/*").to_a
    gem_files += Dir.glob("bin/*").to_a
    gem_files += Dir.glob("docs/**/*").to_a
    gem_files += Dir.glob("std/**/*").to_a

    gem_files
  end

  spec.executables = %w[mtc]
  spec.require_paths = %w[lib]

  spec.add_dependency "rake",     "~> 13.4"
  spec.add_dependency "rexml",    "~> 3.4"
  spec.add_dependency "fiddle"
  spec.add_dependency "racc",     "~> 1.8"
  spec.add_dependency "tomlrb",   "~> 2.0", ">= 2.0.4"
  spec.add_dependency "sinatra",  "~> 4.0"
  spec.add_dependency "rackup",   "~> 2.0"
  spec.add_dependency "puma",     "~> 6.0"

  spec.post_install_message = <<~MSG
    Milk Tea #{MilkTea::VERSION} installed!

    System requirements:
      - A C compiler (gcc or clang) must be available on PATH
      - Optional: cmake + ninja for vendored C libraries (SDL3, GLFW, etc.)
      - Optional: git for bootstrapping vendored library sources on first use

    Get started: mtc run hello.mt
  MSG
end
