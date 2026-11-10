# frozen_string_literal: true

RSpec.describe Autofax::Client, "caching" do
  describe "SQLite cache sharing" do
    before { stub_fixture("/vehicles/", "vehicles_index.html") }

    it "reuses results across client instances" do
      first = Autofax::Client.new.get_makes
      second = Autofax::Client.new.get_makes

      expect(second).to eq(first)
      expect(a_request(:get, "https://autofactsdb.com/vehicles/")).to have_been_made.once
    end

    it "returns the same display text for both display modes" do
      transformed = Autofax::Client.new(display: :transformed).get_makes
      original = Autofax::Client.new(display: :original).get_makes

      expect(transformed.makes).to include("Honda", "Toyota")
      expect(original.makes).to include("Honda", "Toyota")
      expect(transformed).to eq(original)
      expect(a_request(:get, "https://autofactsdb.com/vehicles/")).to have_been_made.once
    end
  end

  describe "#cache_stats and clearing" do
    before { stub_fixture("/vehicles/", "vehicles_index.html") }

    it "reports cache statistics" do
      client = Autofax::Client.new
      client.get_makes

      stats = client.cache_stats
      expect(stats["caching_enabled"]).to eq(true)
      expect(stats["cache_backend"]).to eq("sqlite")
    end

    it "clears the cache" do
      client = Autofax::Client.new
      client.get_makes
      expect(a_request(:get, "https://autofactsdb.com/vehicles/")).to have_been_made.once

      client.clear_all_caches
      client.get_makes
      expect(a_request(:get, "https://autofactsdb.com/vehicles/")).to have_been_made.twice
    end
  end

  describe "memory backend" do
    before { stub_fixture("/vehicles/", "vehicles_index.html") }

    it "does not share state across clients" do
      Autofax::Client.new(cache_backend: :memory).get_makes
      Autofax::Client.new(cache_backend: :memory).get_makes

      expect(a_request(:get, "https://autofactsdb.com/vehicles/")).to have_been_made.twice
    end
  end

  describe "parts cache fidelity" do
    before do
      stub_fixture("/vehicles/honda/2021/civic/brake-and-wheel-hub-parts/", "category_brake_and_wheel_hub.html")
    end

    it "preserves distinct brand listings that share a part number" do
      fresh = Autofax::Client.new.get_parts_by_category("Honda", 2021, "Civic", "15l-l4-turbocharged", "Brake & Wheel Hub")
      cached = Autofax::Client.new.get_parts_by_category("Honda", 2021, "Civic", "15l-l4-turbocharged", "Brake & Wheel Hub")

      expect(cached.count).to eq(fresh.count)
      expect(cached.parts.map(&:url)).to eq(fresh.parts.map(&:url))
      expect(a_request(:get, "https://autofactsdb.com/vehicles/honda/2021/civic/brake-and-wheel-hub-parts/"))
        .to have_been_made.once
    end
  end
end
