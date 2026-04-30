# frozen_string_literal: true

require "pathname"

module MilkTea
  def self.root
    @root ||= Pathname.new(File.expand_path("../..", __dir__))
  end
end
