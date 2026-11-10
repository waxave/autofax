# frozen_string_literal: true

require "stringio"

RSpec.describe Autofax::CLI do
  def run_cli(args)
    out = StringIO.new
    err = StringIO.new
    status = described_class.main(args, out: out, err: err, input: StringIO.new(""))
    [status, out.string, err.string]
  end

  describe "vehicle catalog commands" do
    before do
      stub_fixture("/vehicles/", "vehicles_index.html")
      stub_fixture("/vehicles/honda/", "make_honda.html")
      stub_fixture("/vehicles/honda/2021/", "year_honda_2021.html")
      stub_fixture("/vehicles/honda/2021/civic/", "model_honda_2021_civic.html")
    end

    it "prints makes using the site's display text" do
      status, out, = run_cli(%w[makes])
      expect(status).to eq(0)
      parsed = JSON.parse(out)
      expect(parsed["makes"]).to include("Honda")
      expect(parsed["makes"]).not_to include("HONDA")
    end

    it "produces identical output for --display original and --display transformed" do
      original_status, original_out, = run_cli(%w[--display original makes])
      transformed_status, transformed_out, = run_cli(%w[--display transformed makes])

      expect(original_status).to eq(0)
      expect(transformed_status).to eq(0)
      expect(JSON.parse(original_out)["makes"]).to include("Honda")
      expect(JSON.parse(transformed_out)["makes"]).to include("Honda")
      expect(JSON.parse(transformed_out)).to eq(JSON.parse(original_out))
    end

    it "accepts --json as an explicit output flag" do
      status, out, = run_cli(%w[--json makes])
      expect(status).to eq(0)
      expect(JSON.parse(out)["makes"]).to include("Honda")
    end

    it "prints years" do
      status, out, = run_cli(%w[years Honda])
      expect(status).to eq(0)
      expect(JSON.parse(out)["years"].first).to eq(2026)
    end

    it "prints engines" do
      status, out, = run_cli(%w[engines Honda 2021 Civic])
      expect(status).to eq(0)
      expect(JSON.parse(out)["engines"].length).to eq(3)
    end
  end

  describe "brands commands" do
    before do
      stub_fixture("/part/", "part_index.html")
      stub_fixture("/part/denso/", "brand_denso.html")
    end

    it "prints part brands preserving brand casing" do
      status, out, = run_cli(%w[brands])
      expect(status).to eq(0)
      parsed = JSON.parse(out)
      expect(parsed["count"]).to be > 100
      expect(parsed["brands"].map { |brand| brand["name"] }).to include("DENSO")
    end

    it "keeps brand casing under --display transformed" do
      status, out, = run_cli(%w[--display transformed brands])
      expect(status).to eq(0)
      names = JSON.parse(out)["brands"].map { |brand| brand["name"] }
      expect(names).to include("DENSO")
      expect(names).not_to include("Denso")
    end

    it "prints brand parts" do
      status, out, = run_cli(%w[brand denso])
      expect(status).to eq(0)
      expect(JSON.parse(out)["count"]).to be > 0
    end
  end

  describe "unsupported commands" do
    it "prints a clear error and exits 1" do
      status, out, err = run_cli(%w[tools])
      expect(status).to eq(1)
      expect(out).to eq("")
      expect(err).to include("not available on AutoFactsDB")
    end
  end

  describe "cache commands" do
    it "prints cache stats" do
      status, out, = run_cli(%w[cache stats])
      expect(status).to eq(0)
      expect(JSON.parse(out)["caching_enabled"]).to eq(true)
    end
  end
end
