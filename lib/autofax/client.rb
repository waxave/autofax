# frozen_string_literal: true

require "json"
require "set"
require "uri"
require "nokogiri"

module Autofax
  # Main AutoFactsDB.com API client.
  #
  # Mirrors the Punkauto public API (same method names, model types, and CLI
  # behaviour) but talks to AutoFactsDB's static HTML catalog instead of
  # RockAuto's JSON catalog API. Features that only exist on RockAuto — orders,
  # accounts, login, and the tools catalog — raise `NotSupportedError`.
  class Client < BaseClient
    attr_reader :cache_config, :dropdown_cache_hours, :display

    def initialize(
      use_mobile_profile: true,
      language: "en",
      enable_caching: true,
      part_cache_hours: 12,
      search_cache_hours: 12,
      dropdown_cache_hours: 24,
      max_cached_parts: 1000,
      max_cached_searches: 100,
      cache_backend: :sqlite,
      cache_path: nil,
      display: :original
    )
      @display = display.respond_to?(:to_sym) ? display.to_sym : display
      unless %i[original transformed].include?(@display)
        raise ArgumentError, "display must be :original or :transformed"
      end
      super(use_mobile_profile: use_mobile_profile, language: language)

      @cache_config = CacheConfiguration.new(
        enabled: enable_caching,
        part_ttl_hours: part_cache_hours,
        result_ttl_hours: search_cache_hours,
        max_parts: max_cached_parts,
        max_results: max_cached_searches
      )

      @part_cache = enable_caching ? @cache_config.create_cache : nil
      @cache_backend = cache_backend.to_sym
      @cache_path = cache_path
      unless %i[sqlite memory].include?(@cache_backend)
        raise ArgumentError, "cache_backend must be :sqlite or :memory"
      end
      @result_cache = if enable_caching
                        if @cache_backend == :sqlite
                          SQLiteResultCache.new(path: cache_path || ENV["AUTOFAX_CACHE_PATH"] || SQLiteResultCache::DEFAULT_PATH,
                                                max_entries: max_cached_parts + max_cached_searches)
                        else
                          MemoryResultCache.new(max_entries: max_cached_parts + max_cached_searches)
                        end
                      end

      @dropdown_cache_hours = dropdown_cache_hours
      @manufacturer_cache = nil
      @part_brands_cache = nil
    end

    # Convenience helper that closes the HTTP session after the block.
    def with
      yield self
    ensure
      close
    end

    # === VEHICLE CATALOG ===

    def get_makes
      doc = fetch_doc("/vehicles/")

      makes = Set.new
      doc.css("li a[href]").each do |link|
        href = link["href"].to_s
        next unless href.match?(%r{\A/vehicles/[a-z0-9-]+/\z})

        name = text_of(link)
        makes.add(name) unless name.empty?
      end

      # Fallback for page layouts that only render make cards.
      if makes.empty?
        doc.css("a.card.make-card").each do |link|
          name = text_of(link.at_css("h3"))
          makes.add(name) unless name.empty?
        end
      end

      sorted = makes.to_a.sort
      VehicleMakes.new(makes: sorted, count: sorted.length)
    rescue StandardError => e
      raise Error, "Failed to fetch makes: #{e.message}"
    end

    def get_years_for_make(make)
      make_slug = Slugify.slugify(make)
      doc = fetch_doc("/vehicles/#{make_slug}/")
      prefix = "/vehicles/#{make_slug}/"

      years = Set.new
      doc.css("a.card.archive-card[href]").each do |link|
        href = link["href"].to_s
        next unless href.start_with?(prefix)

        match = href.delete_prefix(prefix).match(/\A(\d{4})\/?\z/)
        years.add(match[1].to_i) if match
      end

      sorted = years.to_a.sort.reverse
      VehicleYears.new(make: make, years: sorted, count: sorted.length)
    rescue StandardError => e
      raise Error, "Failed to fetch years for #{make}: #{e.message}"
    end

    def get_models_for_make_year(make, year)
      make_slug = Slugify.slugify(make)
      doc = fetch_doc("/vehicles/#{make_slug}/#{year}/")
      prefix = "/vehicles/#{make_slug}/#{year}/"

      models = Set.new
      doc.css("a.card.archive-card[href]").each do |link|
        href = link["href"].to_s
        next unless href.start_with?(prefix)

        name = text_of(link.at_css("h3"))
        models.add(name) if name && name.length > 1
      end

      sorted = models.to_a.sort
      VehicleModels.new(make: make, year: year, models: sorted, count: sorted.length)
    rescue StandardError => e
      raise Error, "Failed to fetch models for #{make} #{year}: #{e.message}"
    end

    def get_engines_for_vehicle(make, year, model)
      make_slug = Slugify.slugify(make)
      model_slug = Slugify.slugify(model)
      doc = fetch_doc("/vehicles/#{make_slug}/#{year}/#{model_slug}/")

      engines = []
      doc.css("a.card.engine-card[href]").each do |link|
        href = link["href"].to_s
        description = text_of(link.at_css("h3"))
        next if description.empty?

        carcode = href.strip("/").split("/").last
        next if carcode.empty? || carcode.include?("-parts")

        engines << Engine.new(description: description, carcode: carcode, href: href)
      end

      VehicleEngines.new(make: make, year: year, model: model, engines: engines, count: engines.length)
    rescue StandardError => e
      raise Error, "Failed to fetch engines for #{make} #{year} #{model}: #{e.message}"
    end

    def get_part_categories(make, year, model, carcode)
      make_slug = Slugify.slugify(make)
      model_slug = Slugify.slugify(model)
      doc = fetch_doc("/vehicles/#{make_slug}/#{year}/#{model_slug}/")

      categories = doc.css("a.card.cat-card[href]").filter_map do |link|
        href = link["href"].to_s
        name = text_of(link.at_css("h3"))
        next if name.empty?

        PartCategory.new(name: name, group_name: category_slug_from_href(href), href: href)
      end

      VehiclePartCategories.new(
        make: make, year: year, model: model,
        carcode: carcode, categories: categories, count: categories.length
      )
    rescue StandardError => e
      raise Error, "Failed to fetch part categories: #{e.message}"
    end

    # Search parts for a "carcode" directly, without a full vehicle context.
    #
    # Not supported: AutoFactsDB has no globally-unique carcode. Engine slugs
    # are scoped to a make/year/model, so categories cannot be resolved from an
    # engine slug alone. Use `get_vehicle` + `get_part_categories` instead.
    def search_parts(carcode)
      not_supported!("search_parts (carcode lookup)")
    end

    def get_parts_by_category(make, year, model, carcode, category_group_name)
      make_slug = Slugify.slugify(make)
      model_slug = Slugify.slugify(model)
      category_slug = Slugify.category_slug(category_group_name)

      doc = fetch_doc("/vehicles/#{make_slug}/#{year}/#{model_slug}/#{category_slug}-parts/")
      parts = parse_parts_from_category(doc, carcode)

      VehiclePartsResult.new(
        make: make, year: year, model: model,
        carcode: carcode, category: category_group_name,
        parts: parts, count: parts.length
      )
    rescue StandardError => e
      raise Error, "Failed to fetch parts for category: #{e.message}"
    end

    # Individual parts for a subcategory URL. Not supported: AutoFactsDB
    # subcategories are inline sections on a category page, not separate URLs.
    def get_individual_parts_from_subcategory(*)
      not_supported!("get_individual_parts_from_subcategory")
    end

    # === VEHICLE-SCOPED OPERATIONS ===

    def get_vehicle(make, year, model, engine_index: 0)
      engines_result = get_engines_for_vehicle(make, year, model)
      raise Error, "No engines found for #{make} #{year} #{model}" if engines_result.engines.empty?
      if engine_index >= engines_result.engines.length
        raise Error, "Engine index #{engine_index} out of range. Available engines: #{engines_result.engines.length}"
      end

      selected_engine = engines_result.engines[engine_index]

      vehicle = Vehicle.new(make: make, year: year, model: model, engine: selected_engine)
      vehicle.client = self
      vehicle
    rescue StandardError => e
      raise Error, "Failed to create vehicle: #{e.message}"
    end

    # === PARTS SEARCH ===

    # Manufacturers map to AutoFactsDB part brands. `value` is the brand slug
    # and `text` the brand name.
    def get_manufacturers(use_cache: true)
      return @manufacturer_cache if use_cache && @manufacturer_cache

      brands = get_part_brands(use_cache: use_cache)
      manufacturers = brands.brands.map do |brand|
        PartSearchOption.new(value: brand.slug, text: brand.name)
      end

      @manufacturer_cache = ManufacturerOptions.new(
        manufacturers: manufacturers,
        count: manufacturers.length,
        last_updated: Time.now.iso8601
      )
    rescue StandardError => e
      raise Error, "Failed to fetch manufacturers: #{e.message}"
    end

    # Part group dropdowns don't exist on AutoFactsDB.
    def get_part_groups(*)
      not_supported!("get_part_groups")
    end

    # Part type dropdowns don't exist on AutoFactsDB.
    def get_part_types(*)
      not_supported!("get_part_types")
    end

    def search_parts_by_number(part_number, manufacturer: nil, part_group: nil, part_type: nil, part_name: nil)
      query = [manufacturer, part_name || part_number].compact.map(&:to_s).reject(&:empty?).join(" ")

      doc = fetch_doc("/search/?q=#{URI.encode_www_form_component(query)}")
      parts = parse_search_results(doc)

      PartSearchResult.new(
        parts: parts,
        count: parts.length,
        search_term: part_number,
        manufacturer: manufacturer || "All",
        part_group: part_group || "All"
      )
    rescue StandardError => e
      raise Error, "Failed to search parts: #{e.message}"
    end

    # RockAuto's client-side "what is this part called" autocomplete.
    def what_is_part_called(*)
      not_supported!("what_is_part_called")
    end

    def clear_parts_search_cache
      @manufacturer_cache = nil
      @part_brands_cache = nil
    end

    # === BRANDS (AutoFactsDB native) ===

    def get_part_brands(use_cache: true)
      return @part_brands_cache if use_cache && @part_brands_cache

      doc = fetch_doc("/part/")
      seen = Set.new
      brands = doc.css("a.card.brand-card[href]").filter_map do |link|
        href = link["href"].to_s
        slug = href.strip("/").split("/").last
        name = text_of(link.at_css(".brand-card-name"))
        next if slug.empty? || slug == "part" || name.empty?
        next unless seen.add?(slug)

        PartBrand.new(name: name, slug: slug, part_count: nil, href: href)
      end

      @part_brands_cache = PartBrands.new(brands: brands, count: brands.length, last_updated: Time.now.iso8601)
    rescue StandardError => e
      raise Error, "Failed to fetch part brands: #{e.message}"
    end

    def get_brand_parts(brand_slug)
      slug = Slugify.slugify(brand_slug)
      doc = fetch_doc("/part/#{slug}/")
      brand_name = slug.split("-").map(&:capitalize).join(" ")

      parts = doc.css("a.card.part-card[href]").filter_map do |link|
        href = link["href"].to_s
        part_number = text_of(link.at_css("strong"))
        next if part_number.empty?

        name = text_of(link.at_css(".small.muted"))
        PartInfo.new(
          name: name.empty? ? part_number : name,
          part_number: part_number,
          brand: brand_name,
          url: href,
          info_url: href
        )
      end

      PartSearchResult.new(parts: parts, count: parts.length, search_term: slug, manufacturer: brand_name)
    rescue StandardError => e
      raise Error, "Failed to fetch parts for brand: #{e.message}"
    end

    def get_part(brand_slug, part_number)
      brand = Slugify.slugify(brand_slug)
      number = part_number.to_s.strip
      doc = fetch_doc("/part/#{brand}/#{number}/")

      heading = text_of(doc.at_css("h1"))
      brand_name = brand_from_heading(heading, number) || brand.split("-").map(&:capitalize).join(" ")
      name = heading.sub(/\A#{Regexp.escape(brand_name)}\s+#{Regexp.escape(number)}\s*/i, "").strip
      name = heading if name.empty?

      notes = doc.css(".note-pill").map { |node| text_of(node) }.reject(&:empty?).uniq
      markets = doc.css(".market-badge").filter_map { |node| node["data-market"] }
      fitments = parse_fitments(doc)

      PartDetail.new(
        brand: brand_name,
        part_number: number,
        name: name,
        url: "/part/#{brand}/#{number}/",
        notes: notes,
        markets: markets,
        fitments: fitments,
        count: fitments.length
      )
    rescue StandardError => e
      raise Error, "Failed to fetch part: #{e.message}"
    end

    # === CACHE MANAGEMENT ===

    def cache_stats
      stats = {
        "caching_enabled" => @cache_config.enabled,
        "cache_settings" => {
          "part_cache_hours" => @cache_config.part_ttl_hours,
          "search_cache_hours" => @cache_config.result_ttl_hours,
          "dropdown_cache_hours" => @dropdown_cache_hours,
          "max_cached_parts" => @cache_config.max_parts,
          "max_cached_searches" => @cache_config.max_results
        },
        "dropdown_caches" => {
          "manufacturers_cached" => !@manufacturer_cache.nil?,
          "part_brands_cached" => !@part_brands_cache.nil?
        },
        "part_cache" => nil
      }

      stats["part_cache"] = @part_cache.cache_stats if @part_cache
      stats["persistent_cache"] = @result_cache&.stats
      stats["cache_backend"] = @cache_backend.to_s
      stats
    end

    def clear_all_caches
      cleared = {
        "manufacturers" => !@manufacturer_cache.nil?,
        "part_brands" => !@part_brands_cache.nil?,
        "parts_cleared" => 0,
        "searches_cleared" => 0
      }

      @manufacturer_cache = nil
      @part_brands_cache = nil

      if @part_cache
        stats = @part_cache.cache_stats
        cleared["parts_cleared"] = stats[:cached_parts]
        cleared["searches_cleared"] = stats[:cached_results]
        @part_cache.clear_all
      end

      cleared["result_cache_entries_cleared"] = @result_cache ? @result_cache.clear : 0

      cleared
    end

    def clear_expired_caches
      cleared = { "expired_parts" => 0, "expired_searches" => 0, "expired_dropdowns" => 0 }

      cutoff = Time.now - (@dropdown_cache_hours * 3600)

      [["@manufacturer_cache", @manufacturer_cache], ["@part_brands_cache", @part_brands_cache]].each do |ivar, cache|
        next unless cache
        next unless cache.respond_to?(:last_updated) && cache.last_updated

        if Time.iso8601(cache.last_updated) < cutoff
          cleared["expired_dropdowns"] += 1
          instance_variable_set(ivar, nil)
        end
      end

      if @part_cache
        expired_parts, expired_searches = @part_cache.clear_expired
        cleared["expired_parts"] = expired_parts
        cleared["expired_searches"] = expired_searches
      end

      cleared["expired_result_entries"] = @result_cache ? @result_cache.clear_expired : 0

      cleared
    end

    def configure_cache(enable_caching: nil, part_cache_hours: nil, search_cache_hours: nil,
                        dropdown_cache_hours: nil, max_cached_parts: nil, max_cached_searches: nil)
      unless enable_caching.nil?
        @cache_config.enabled = enable_caching
        if !enable_caching
          @part_cache = nil
          @result_cache = nil
        elsif @part_cache.nil?
          @part_cache = @cache_config.create_cache
          @result_cache = if @cache_backend == :sqlite
                            SQLiteResultCache.new(path: @cache_path || ENV["AUTOFAX_CACHE_PATH"] || SQLiteResultCache::DEFAULT_PATH)
                          else
                            MemoryResultCache.new(max_entries: @cache_config.max_parts + @cache_config.max_results)
                          end
        end
      end

      @cache_config.part_ttl_hours = part_cache_hours unless part_cache_hours.nil?
      @cache_config.result_ttl_hours = search_cache_hours unless search_cache_hours.nil?
      @dropdown_cache_hours = dropdown_cache_hours unless dropdown_cache_hours.nil?

      unless max_cached_parts.nil?
        @cache_config.max_parts = max_cached_parts
        @part_cache.max_parts = max_cached_parts if @part_cache
      end

      unless max_cached_searches.nil?
        @cache_config.max_results = max_cached_searches
        @part_cache.max_results = max_cached_searches if @part_cache
      end

      cache_stats
    end

    # === UNSUPPORTED (RockAuto-only features) ===

    def get_tool_categories(*)
      not_supported!("get_tool_categories")
    end

    def get_tools_by_category(*)
      not_supported!("get_tools_by_category")
    end

    def lookup_order_status(*)
      not_supported!("lookup_order_status")
    end

    def request_order_list(*)
      not_supported!("request_order_list")
    end

    def login(*)
      not_supported!("login")
    end

    def logout
      not_supported!("logout")
    end

    def authentication_status
      { "is_authenticated" => false, "user_email" => nil, "has_session_cookies" => false }
    end

    def add_external_order(*)
      not_supported!("add_external_order")
    end

    def get_saved_addresses
      not_supported!("get_saved_addresses")
    end

    def get_saved_vehicles
      not_supported!("get_saved_vehicles")
    end

    def get_account_activity
      not_supported!("get_account_activity")
    end

    def get_order_history(*)
      not_supported!("get_order_history")
    end

    private

    def fetch_doc(path)
      response = get(path)
      unless response.status.to_i.between?(200, 299)
        raise Error, "Request to #{path} failed with status #{response.status}"
      end

      Nokogiri::HTML(response.body.to_s)
    end

    def parse_parts_from_category(doc, carcode)
      parts = []
      engine = carcode.to_s.strip

      doc.css("article.post-body section.subcat-section").each do |section|
        subcat_name = text_of(section.at_css("h2"))
        section.css("details.tier-block table.parts tbody tr").each do |row|
          data_engines = row["data-engines"].to_s.split
          next if !engine.empty? && !data_engines.empty? && !data_engines.include?(engine)

          part = extract_part_from_row(row, subcat_name)
          parts << part if part
        end
      end

      parts
    end

    def extract_part_from_row(row, subcat_name)
      brand = text_of(row.at_css(".brand-link"))
      pn_link = row.at_css(".pn-link")
      return nil unless pn_link

      part_number = text_of(pn_link)
      return nil if part_number.empty?

      notes = row.css(".note-pill").map { |node| text_of(node) }.reject(&:empty?)
      buy_url = row.at_css("a.btn--amazon")&.[]("href")
      href = pn_link["href"]

      PartInfo.new(
        name: subcat_name.empty? ? part_number : subcat_name,
        part_number: part_number,
        price: nil,
        brand: brand.empty? ? nil : brand,
        url: href,
        image_url: nil,
        info_url: href,
        video_url: nil,
        buy_url: buy_url,
        compatibility_notes: notes.empty? ? nil : notes.join("; ")
      )
    end

    def parse_search_results(doc)
      doc.css(".search-results .search-result a.card[href]").filter_map do |link|
        href = link["href"].to_s
        segments = href.strip("/").split("/")
        next unless segments.length >= 2 && segments[0] == "part"

        part_number = segments.last
        next if part_number.empty?

        strong = text_of(link.at_css("strong"))
        name = strong.include?("—") ? strong.split("—", 2).last.strip : nil
        brand = brand_from_heading(strong, part_number) || segments[-2].split("-").map(&:capitalize).join(" ")

        category = link.at_css(".small.muted") ? text_of(link.at_css(".small.muted")) : nil
        fitment = link.at_css(".small:not(.muted)") ? text_of(link.at_css(".small:not(.muted)")) : nil

        PartInfo.new(
          name: name && !name.empty? ? name : part_number,
          part_number: part_number,
          brand: brand,
          url: href,
          info_url: href,
          category: category,
          compatibility_notes: fitment
        )
      end
    end

    def parse_fitments(doc)
      doc.css("table.fitment-table tbody tr").filter_map do |row|
        cells = row.css("td")
        next unless cells.length >= 4

        year = cells[0]["data-value"].to_i
        make = cells[1]["data-value"]
        model_link = cells[2].at_css("a")
        model = cells[2]["data-value"] || (model_link ? text_of(model_link) : "")
        engine = cells[3]["data-value"]
        url = model_link ? model_link["href"] : nil
        engine_slug = url.to_s[/#engine=([a-z0-9-]+)/, 1]

        Fitment.new(year: year, make: make, model: model, engine: engine, engine_slug: engine_slug, url: url)
      end
    end

    def brand_from_heading(heading, part_number)
      return nil if heading.nil? || heading.empty? || part_number.nil? || part_number.empty?

      index = heading.index(part_number)
      return nil unless index && index.positive?

      heading[0...index].strip
    end

    def category_slug_from_href(href)
      href.to_s.strip("/").split("/").last.to_s.sub(/-parts\z/, "")
    end

    def not_supported!(feature)
      raise NotSupportedError, "#{feature} is not available on AutoFactsDB (it has no #{unsupported_area(feature)})."
    end

    def unsupported_area(feature)
      case feature
      when "get_tool_categories", "get_tools_by_category" then "tools catalog"
      when "lookup_order_status", "request_order_list" then "public order lookup"
      when "login", "logout", "get_saved_addresses", "get_saved_vehicles",
           "get_account_activity", "get_order_history", "add_external_order" then "account/login system"
      when "get_individual_parts_from_subcategory" then "subcategory URLs"
      when "search_parts (carcode lookup)" then "global carcode identifier"
      when "what_is_part_called", "get_part_groups", "get_part_types" then "parts-search dropdown"
      else "equivalent feature"
      end
    end

    def text_of(node)
      return "" if node.nil?

      node.text.gsub(/\s+/, " ").strip
    end
  end
end
