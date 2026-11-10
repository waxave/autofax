# frozen_string_literal: true

module Autofax
  # Years available for a specific make.
  class VehicleYears < Model
    attribute :make   # Vehicle make
    attribute :years  # Available years in descending order
    attribute :count  # Total number of years
  end
end
