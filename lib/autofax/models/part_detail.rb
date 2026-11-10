# frozen_string_literal: true

module Autofax
  # A single year/make/model/engine configuration a part is confirmed to fit.
  class Fitment < Model
    attribute :year
    attribute :make
    attribute :model
    attribute :engine
    attribute :engine_slug, default: nil
    attribute :url, default: nil
  end

  # Full detail for a single part, including its fitment guide.
  class PartDetail < Model
    attribute :brand, default: nil
    attribute :part_number
    attribute :name, default: nil
    attribute :url, default: nil
    attribute :category, default: nil
    attribute :notes, default: -> { [] }
    attribute :markets, default: -> { [] }
    attribute :fitments, default: -> { [] }
    attribute :count, default: 0
  end
end
