# frozen_string_literal: true

require "pathname"

require_relative 'milk_tea/token'
require_relative 'milk_tea/lexer'
require_relative 'milk_tea/ast'
require_relative 'milk_tea/parser'
require_relative 'milk_tea/module_loader'
require_relative 'milk_tea/bindgen'
require_relative 'milk_tea/sema'
require_relative 'milk_tea/types'
require_relative 'milk_tea/ir'
require_relative 'milk_tea/lowering'
require_relative 'milk_tea/codegen'
require_relative 'milk_tea/c_backend'
require_relative 'milk_tea/cli'

module MilkTea
  def self.root
    @root ||= Pathname.new(File.expand_path('..', __dir__))
  end
end
