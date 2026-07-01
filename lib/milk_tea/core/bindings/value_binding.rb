# frozen_string_literal: true

module MilkTea
  ValueBinding = Data.define(:id, :name, :storage_type, :flow_type, :mutable, :kind, :const_value) do
    def type
      flow_type || storage_type
    end

    def with_flow_type(refined_type)
      ValueBinding.new(
        id:,
        name:,
        storage_type:,
        flow_type: refined_type == storage_type ? nil : refined_type,
        mutable:,
        kind:,
        const_value:,
      )
    end
  end
end
