# frozen_string_literal: true

RSpec.describe "display text handling" do
  let(:client) { Autofax::Client.new }

  describe "client results use AutoFactsDB's display text verbatim" do
    before do
      stub_fixture("/vehicles/", "vehicles_index.html")
      stub_fixture("/vehicles/honda/2021/", "year_honda_2021.html")
      stub_fixture("/part/", "part_index.html")
    end

    it "preserves mixed and acronym casing in makes" do
      makes = client.get_makes.makes
      expect(makes).to include("Honda", "BMW", "GMC", "KIA", "MINI")
      expect(makes).not_to include("Bmw", "Gmc", "Kia", "Mini")
    end

    it "returns model names as shown on the site" do
      models = client.get_models_for_make_year("Honda", 2021).models
      expect(models).to include("Civic", "Accord")
      expect(models).not_to include("CIVIC")
    end

    it "preserves brand casing" do
      names = client.get_part_brands.brands.map(&:name)
      expect(names).to include("DENSO")
      expect(names).not_to include("Denso")
    end
  end

  describe "display: :transformed is a no-op" do
    before do
      stub_fixture("/vehicles/", "vehicles_index.html")
      stub_fixture("/vehicles/honda/2021/", "year_honda_2021.html")
      stub_fixture("/part/", "part_index.html")
    end

    it "matches :original for makes" do
      expect(Autofax::Client.new(display: :transformed).get_makes)
        .to eq(Autofax::Client.new(display: :original).get_makes)
    end

    it "matches :original for models" do
      expect(Autofax::Client.new(display: :transformed).get_models_for_make_year("Honda", 2021))
        .to eq(Autofax::Client.new(display: :original).get_models_for_make_year("Honda", 2021))
    end

    it "matches :original for brand lists" do
      expect(Autofax::Client.new(display: :transformed).get_part_brands)
        .to eq(Autofax::Client.new(display: :original).get_part_brands)
    end
  end

  describe "Vehicle" do
    before { stub_fixture("/vehicles/honda/2021/civic/", "model_honda_2021_civic.html") }

    it "keeps the make/model display text" do
      vehicle = client.get_vehicle("Honda", 2021, "Civic")
      expect(vehicle.make).to eq("Honda")
      expect(vehicle.model).to eq("Civic")
    end
  end
end
