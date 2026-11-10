# frozen_string_literal: true

module Autofax
  # URL slug helpers for AutoFactsDB's deterministic path scheme.
  #
  # AutoFactsDB slugs lowercase names, spell out "&" as "and", and join words
  # with single hyphens (e.g. "Brake & Wheel Hub" => "brake-and-wheel-hub",
  # "Mercedes-Benz" => "mercedes-benz", "CR-V" => "cr-v").
  module Slugify
    module_function

    def slugify(text)
      value = text.to_s
      value = value.gsub(/&/, " and ")
      value = value.downcase
      value = value.gsub(/[^a-z0-9]+/, "-")
      value = value.gsub(/\A-+|-+\z/, "")
      value.gsub(/-{2,}/, "-")
    end

    # Slug for a part category. Accepts a display name ("Brake & Wheel Hub")
    # or an already-slugged value ("brake-and-wheel-hub").
    def category_slug(name_or_slug)
      value = name_or_slug.to_s.strip
      return value if value.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)

      slugify(value)
    end
  end
end
