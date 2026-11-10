# frozen_string_literal: true

module Autofax
  # Parts results for a specific vehicle and category.
  class VehiclePartsResult < Model
    attribute :make      # Vehicle make
    attribute :year      # Vehicle year
    attribute :model     # Vehicle model
    attribute :carcode   # Engine slug (vehicle identifier)
    attribute :category  # Part category name
    attribute :parts     # Found parts
    attribute :count     # Total number of parts found
  end
end
