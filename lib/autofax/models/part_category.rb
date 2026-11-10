# frozen_string_literal: true

module Autofax
  # Represents a part category/group.
  #
  # `name` is the display label ("Brake & Wheel Hub"); `group_name` is the URL
  # slug used to reach the category's parts page ("brake-and-wheel-hub").
  class PartCategory < Model
    attribute :name        # Category name (e.g., 'Brake & Wheel Hub')
    attribute :group_name  # URL slug for the category page
    attribute :href, default: nil
  end
end
