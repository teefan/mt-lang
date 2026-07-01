# frozen_string_literal: true

module MilkTea
  AttributeBinding = Data.define(:name, :targets, :params, :module_name, :builtin, :ast)
  BUILTIN_ATTRIBUTE_NAMES = %w[packed align deprecated test expect_fatal].freeze

  module_function

  def builtin_attribute_binding(name, types)
    case name
    when "packed"
      AttributeBinding.new(
        name: "packed",
        targets: [:struct].freeze,
        params: [].freeze,
        module_name: nil,
        builtin: true,
        ast: nil,
      )
    when "align"
      AttributeBinding.new(
        name: "align",
        targets: [:struct].freeze,
        params: [Types::Registry.parameter("bytes", types.fetch("ptr_uint"))].freeze,
        module_name: nil,
        builtin: true,
        ast: nil,
      )
    when "deprecated"
      AttributeBinding.new(
        name: "deprecated",
        targets: %i[callable struct const enum flags union variant event].freeze,
        params: [Types::Registry.parameter("message", types.fetch("str"))].freeze,
        module_name: nil,
        builtin: true,
        ast: nil,
      )
    when "test"
      AttributeBinding.new(
        name: "test",
        targets: [:callable].freeze,
        params: [].freeze,
        module_name: nil,
        builtin: true,
        ast: nil,
      )
    when "expect_fatal"
      AttributeBinding.new(
        name: "expect_fatal",
        targets: [:callable].freeze,
        params: [].freeze,
        module_name: nil,
        builtin: true,
        ast: nil,
      )
    end
  end
end
