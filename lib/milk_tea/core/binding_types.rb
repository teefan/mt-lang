# frozen_string_literal: true

require_relative "bindings/value_binding"
require_relative "bindings/function_binding"
require_relative "bindings/module_binding"
require_relative "bindings/attribute_binding"

module MilkTea
  class FlowScope
    def initialize = (@bindings = {})
    def [](key) = @bindings[key]
    def []=(key, val); @bindings[key] = val; end
    def key?(key) = @bindings.key?(key)
    def empty? = @bindings.empty?
    def each(&block) = @bindings.each(&block)
    def each_with_object(init, &block) = @bindings.each_with_object(init, &block)
  end
end
