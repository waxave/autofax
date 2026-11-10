# frozen_string_literal: true

module Autofax
  # A single part brand in the AutoFactsDB catalog.
  class PartBrand < Model
    attribute :name        # Brand display name (e.g., 'DENSO')
    attribute :slug        # URL slug (e.g., 'denso')
    attribute :part_count, default: nil # Approximate number of part numbers
    attribute :href, default: nil
  end

  # Collection of part brands.
  class PartBrands < Model
    attribute :brands
    attribute :count
    attribute :last_updated, default: nil

    def brand_by_name(name)
      name_lower = name.downcase
      brands.find { |brand| brand.name.downcase == name_lower || brand.slug.downcase == name_lower }
    end

    def brand_names
      brands.map(&:name)
    end
  end
end
