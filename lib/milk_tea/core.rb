# frozen_string_literal: true

require_relative "base"

require_relative "core/token"
require_relative "core/lexer"
require_relative "core/ast"
require_relative "core/parser"
require_relative "core/module_loader"
require_relative "core/sema"
require_relative "core/types"
require_relative "core/ir"
require_relative "core/pretty_printer"
require_relative "core/lowering"
require_relative "core/codegen"
require_relative "core/c_backend"
