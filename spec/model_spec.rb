# frozen_string_literal: true

RSpec.describe Autofax::Model do
  it "raises on a missing required attribute" do
    klass = Class.new(described_class) { attribute :name }
    expect { klass.new }.to raise_error(ArgumentError, /missing keyword: name/)
  end

  it "accepts attributes with defaults" do
    klass = Class.new(described_class) do
      attribute :name
      attribute :count, default: 0
    end
    model = klass.new(name: "x")
    expect(model.name).to eq("x")
    expect(model.count).to eq(0)
  end

  it "implements value equality" do
    klass = Class.new(described_class) { attribute :name }
    expect(klass.new(name: "a")).to eq(klass.new(name: "a"))
    expect(klass.new(name: "a")).not_to eq(klass.new(name: "b"))
  end

  it "exposes attributes via to_h" do
    klass = Class.new(described_class) do
      attribute :name
      attribute :count, default: 0
    end
    expect(klass.new(name: "a").to_h).to eq(name: "a", count: 0)
  end
end

RSpec.describe Autofax::PartBrands do
  it "looks up a brand by name or slug" do
    brands = Autofax::PartBrands.new(
      brands: [Autofax::PartBrand.new(name: "DENSO", slug: "denso")],
      count: 1
    )
    expect(brands.brand_by_name("denso").name).to eq("DENSO")
    expect(brands.brand_by_name("DENSO").name).to eq("DENSO")
    expect(brands.brand_by_name("missing")).to be_nil
  end
end
