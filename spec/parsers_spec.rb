# frozen_string_literal: true

RSpec.describe Autofax::Slugify do
  describe ".slugify" do
    it "lowercases and joins words with hyphens" do
      expect(described_class.slugify("Honda")).to eq("honda")
      expect(described_class.slugify("AM General")).to eq("am-general")
      expect(described_class.slugify("Mercedes-Benz")).to eq("mercedes-benz")
    end

    it "spells out ampersands" do
      expect(described_class.slugify("Brake & Wheel Hub")).to eq("brake-and-wheel-hub")
      expect(described_class.slugify("Body & Lamp Assembly")).to eq("body-and-lamp-assembly")
    end

    it "preserves existing hyphens and digits" do
      expect(described_class.slugify("CR-V")).to eq("cr-v")
      expect(described_class.slugify("BR-V")).to eq("br-v")
    end
  end

  describe ".category_slug" do
    it "passes through an already-slugged value" do
      expect(described_class.category_slug("brake-and-wheel-hub")).to eq("brake-and-wheel-hub")
    end

    it "slugifies a display name" do
      expect(described_class.category_slug("Brake & Wheel Hub")).to eq("brake-and-wheel-hub")
      expect(described_class.category_slug("Electrical-Bulb & Socket")).to eq("electrical-bulb-and-socket")
      expect(described_class.category_slug("Transmission-Automatic")).to eq("transmission-automatic")
    end
  end
end
