# frozen_string_literal: true

module Autofax
  # Represents a vehicle engine configuration.
  #
  # AutoFactsDB identifies an engine by its URL slug (the `carcode` analogue);
  # the human-readable description is the engine name shown on the site.
  class Engine < Model
    attribute :description # Engine description (e.g., '1.5L L4 Turbocharged')
    attribute :carcode     # Engine URL slug, used as the vehicle identifier
    attribute :href, default: nil # Link to engine catalog page
  end
end
