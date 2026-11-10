# frozen_string_literal: true

require "autofax"
require "webmock/rspec"
require "json"
require "nokogiri"
require "tmpdir"
require "fileutils"

WebMock.disable_net_connect!(allow_localhost: true)

FIXTURE_DIR = File.expand_path("fixtures", __dir__).freeze

module FixtureHelpers
  BASE = "https://autofactsdb.com"

  def fixture(name)
    File.read(File.join(FIXTURE_DIR, name))
  end

  def stub_fixture(path, name)
    stub_request(:get, "#{BASE}#{path}")
      .to_return(status: 200, body: fixture(name), headers: { "Content-Type" => "text/html" })
  end
end

RSpec.configure do |config|
  config.include FixtureHelpers

  config.around do |example|
    previous_cache_path = ENV["AUTOFAX_CACHE_PATH"]
    cache_dir = Dir.mktmpdir("autofax-spec-")
    ENV["AUTOFAX_CACHE_PATH"] = File.join(cache_dir, "cache.sqlite3")
    example.run
  ensure
    previous_cache_path ? ENV["AUTOFAX_CACHE_PATH"] = previous_cache_path : ENV.delete("AUTOFAX_CACHE_PATH")
    FileUtils.remove_entry(cache_dir) if cache_dir && File.exist?(cache_dir)
  end

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
