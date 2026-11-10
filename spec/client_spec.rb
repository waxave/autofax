# frozen_string_literal: true

RSpec.describe Autofax::Client do
  describe "#get_makes" do
    before { stub_fixture("/vehicles/", "vehicles_index.html") }

    it "returns sorted makes using the site's display text" do
      result = subject.get_makes
      expect(result).to be_a(Autofax::VehicleMakes)
      expect(result.makes).to include("Honda", "Toyota", "Acura", "BMW")
      expect(result.makes).not_to include("HONDA", "TOYOTA")
      expect(result.makes).to eq(result.makes.sort)
      expect(result.count).to be > 100
    end
  end

  describe "#get_years_for_make" do
    before { stub_fixture("/vehicles/honda/", "make_honda.html") }

    it "returns years in descending order" do
      result = subject.get_years_for_make("Honda")
      expect(result).to be_a(Autofax::VehicleYears)
      expect(result.make).to eq("Honda")
      expect(result.years.first).to eq(2026)
      expect(result.years).to eq(result.years.sort.reverse)
    end
  end

  describe "#get_models_for_make_year" do
    before { stub_fixture("/vehicles/honda/2021/", "year_honda_2021.html") }

    it "returns available models" do
      result = subject.get_models_for_make_year("Honda", 2021)
      expect(result).to be_a(Autofax::VehicleModels)
      expect(result.models).to include("Civic", "Accord", "Pilot")
    end
  end

  describe "#get_engines_for_vehicle" do
    before { stub_fixture("/vehicles/honda/2021/civic/", "model_honda_2021_civic.html") }

    it "returns engine configurations with slug identifiers" do
      result = subject.get_engines_for_vehicle("Honda", 2021, "Civic")
      expect(result).to be_a(Autofax::VehicleEngines)
      expect(result.engines.map(&:description)).to include("1.5L L4 Turbocharged", "2.0L L4")
      expect(result.engines.map(&:carcode)).to include("15l-l4-turbocharged", "20l-l4")
    end
  end

  describe "#get_part_categories" do
    before { stub_fixture("/vehicles/honda/2021/civic/", "model_honda_2021_civic.html") }

    it "returns part categories with slug group names" do
      result = subject.get_part_categories("Honda", 2021, "Civic", "15l-l4-turbocharged")
      expect(result).to be_a(Autofax::VehiclePartCategories)
      brake = result.categories.find { |c| c.name == "Brake & Wheel Hub" }
      expect(brake).not_to be_nil
      expect(brake.group_name).to eq("brake-and-wheel-hub")
    end
  end

  describe "#get_parts_by_category" do
    before { stub_fixture("/vehicles/honda/2021/civic/brake-and-wheel-hub-parts/", "category_brake_and_wheel_hub.html") }

    it "returns parts for the requested engine" do
      result = subject.get_parts_by_category("Honda", 2021, "Civic", "15l-l4-turbocharged", "Brake & Wheel Hub")
      expect(result).to be_a(Autofax::VehiclePartsResult)
      expect(result.count).to be > 0

      part = result.parts.find { |p| p.part_number == "2ABS3508" }
      expect(part).not_to be_nil
      expect(part.brand).to eq("Holstein")
      expect(part.name).to eq("ABS Wheel Speed Sensor")
    end

    it "builds the URL from a display name" do
      subject.get_parts_by_category("Honda", 2021, "Civic", "15l-l4-turbocharged", "Brake & Wheel Hub")
      expect(a_request(:get, "https://autofactsdb.com/vehicles/honda/2021/civic/brake-and-wheel-hub-parts/")).to have_been_made
    end
  end

  describe "#search_parts_by_number" do
    before { stub_fixture("/search/?q=denso", "search_denso.html") }

    it "returns matching parts" do
      result = subject.search_parts_by_number("denso")
      expect(result).to be_a(Autofax::PartSearchResult)
      expect(result.count).to be > 0
      expect(result.parts.first.brand).to eq("DENSO")
      expect(result.parts.first.part_number).to eq("1433001")
    end
  end

  describe "#get_part_brands" do
    before { stub_fixture("/part/", "part_index.html") }

    it "returns part brands" do
      result = subject.get_part_brands
      expect(result).to be_a(Autofax::PartBrands)
      expect(result.count).to be > 100
      denso = result.brand_by_name("denso")
      expect(denso.name).to eq("DENSO")
    end
  end

  describe "#get_manufacturers" do
    before { stub_fixture("/part/", "part_index.html") }

    it "maps brands to manufacturer options" do
      result = subject.get_manufacturers
      expect(result).to be_a(Autofax::ManufacturerOptions)
      option = result.manufacturer_by_name("denso")
      expect(option.value).to eq("denso")
    end
  end

  describe "#get_brand_parts" do
    before { stub_fixture("/part/denso/", "brand_denso.html") }

    it "returns parts for a brand" do
      result = subject.get_brand_parts("denso")
      expect(result).to be_a(Autofax::PartSearchResult)
      expect(result.count).to be > 0
      expect(result.parts.first.brand).to eq("Denso")
      expect(result.parts.first.part_number).to eq("1433001")
    end
  end

  describe "#get_part" do
    before { stub_fixture("/part/holstein/2ABS3508/", "part_holstein_2abs3508.html") }

    it "returns part detail with fitment" do
      result = subject.get_part("holstein", "2ABS3508")
      expect(result).to be_a(Autofax::PartDetail)
      expect(result.brand).to eq("Holstein")
      expect(result.part_number).to eq("2ABS3508")
      expect(result.fitments).not_to be_empty
      expect(result.fitments.first).to be_a(Autofax::Fitment)
      expect(result.fitments.map(&:year)).to include(2021)
    end
  end

  describe "unsupported RockAuto-only features" do
    it "raises NotSupportedError" do
      expect { subject.get_tool_categories }.to raise_error(Autofax::NotSupportedError)
      expect { subject.get_tools_by_category("Engine") }.to raise_error(Autofax::NotSupportedError)
      expect { subject.lookup_order_status("a@b.com", "123") }.to raise_error(Autofax::NotSupportedError)
      expect { subject.request_order_list("email", "a@b.com") }.to raise_error(Autofax::NotSupportedError)
      expect { subject.login("a@b.com", "pw") }.to raise_error(Autofax::NotSupportedError)
      expect { subject.get_saved_vehicles }.to raise_error(Autofax::NotSupportedError)
      expect { subject.get_part_groups }.to raise_error(Autofax::NotSupportedError)
      expect { subject.get_part_types }.to raise_error(Autofax::NotSupportedError)
      expect { subject.what_is_part_called("brake pad") }.to raise_error(Autofax::NotSupportedError)
      expect { subject.search_parts("12345") }.to raise_error(Autofax::NotSupportedError)
      expect { subject.get_individual_parts_from_subcategory("Honda", 2021, "Civic", "/url") }.to raise_error(Autofax::NotSupportedError)
    end
  end

  describe "#get_vehicle" do
    before { stub_fixture("/vehicles/honda/2021/civic/", "model_honda_2021_civic.html") }

    it "returns a scoped vehicle" do
      vehicle = subject.get_vehicle("Honda", 2021, "Civic")
      expect(vehicle).to be_a(Autofax::Vehicle)
      expect(vehicle.carcode).to eq("15l-l4-turbocharged")
      expect(vehicle.engine.description).to eq("1.5L L4 Turbocharged")
    end
  end
end
