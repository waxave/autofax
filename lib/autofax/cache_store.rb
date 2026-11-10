# frozen_string_literal: true

require "json"
require "fileutils"
require "sqlite3"
require "digest"
require "time"

module Autofax
  # Safe JSON-based serialization for the public model objects cached by Client.
  module CacheCodec
    module_function

    def dump(value)
      JSON.generate(encode(value))
    end

    def load(payload)
      decode(JSON.parse(payload))
    end

    def encode(value)
      case value
      when Model
        { "__type" => "model", "class" => value.class.name, "attributes" => raw_attributes(value).transform_values { |v| encode(v) } }
      when Time
        { "__type" => "time", "value" => value.iso8601 }
      when Symbol
        { "__type" => "symbol", "value" => value.to_s }
      when Array then value.map { |v| encode(v) }
      when Hash
        { "__type" => "hash", "entries" => value.map { |k, v| [encode(k), encode(v)] } }
      when String, Numeric, TrueClass, FalseClass, NilClass then value
      else
        raise ArgumentError, "unsupported cached value: #{value.class}"
      end
    end

    def raw_attributes(model)
      model.to_h.merge(model.instance_variable_get(:@raw_display_values) || {})
    end

    def decode(value)
      case value
      when Array then value.map { |v| decode(v) }
      when Hash
        case value["__type"]
        when "model"
          klass = value.fetch("class").split("::").reduce(Object) { |scope, name| scope.const_get(name, false) }
          raise ArgumentError, "not an Autofax model" unless klass <= Model

          attrs = value.fetch("attributes").transform_values { |v| decode(v) }
          klass.new(**attrs.transform_keys(&:to_sym))
        when "time" then Time.iso8601(value.fetch("value"))
        when "symbol" then value.fetch("value").to_sym
        when "hash" then value.fetch("entries").to_h { |k, v| [decode(k), decode(v)] }
        else value.transform_values { |v| decode(v) }
        end
      else value
      end
    end
  end

  # Small interface shared by the persistent and per-client cache backends.
  class MemoryResultCache
    def initialize(max_entries: 1100)
      @entries = {}
      @max_entries = max_entries
    end

    def read(key)
      entry = @entries[key]
      return nil unless entry
      if entry[:expires_at] <= Time.now.to_f
        @entries.delete(key)
        return nil
      end
      entry[:accessed_at] = Time.now.to_f
      entry[:hits] += 1
      entry[:value]
    end

    def write(key, value, ttl_hours:)
      @entries.delete(@entries.min_by { |_k, v| v[:accessed_at] }&.first) if !@entries.key?(key) && @entries.size >= @max_entries
      now = Time.now.to_f
      @entries[key] = { value: value, created_at: now, accessed_at: now,
                        expires_at: now + ttl_hours * 3600, hits: 0 }
    end

    def stats
      { entries: @entries.size, hits: @entries.values.sum { |v| v[:hits] }, path: nil }
    end

    def clear
      count = @entries.size
      @entries.clear
      count
    end

    def clear_expired
      expired = @entries.select { |_k, v| v[:expires_at] <= Time.now.to_f }.keys
      expired.each { |key| @entries.delete(key) }
      expired.length
    end
  end

  # Persistent cache shared across client instances and CLI invocations.
  class SQLiteResultCache
    DEFAULT_PATH = File.join(ENV.fetch("XDG_CACHE_HOME", File.join(Dir.home, ".cache")), "autofax", "cache.sqlite3").freeze

    attr_reader :path

    def initialize(path: ENV.fetch("AUTOFAX_CACHE_PATH", DEFAULT_PATH), max_entries: 1100)
      @path = File.expand_path(path)
      @max_entries = max_entries
      FileUtils.mkdir_p(File.dirname(@path))
      with_db do |db|
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys = ON;
          CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS languages (
            id INTEGER PRIMARY KEY, code TEXT NOT NULL UNIQUE
          );
          CREATE TABLE IF NOT EXISTS entities (
            id INTEGER PRIMARY KEY,
            language_id INTEGER NOT NULL REFERENCES languages(id) ON DELETE CASCADE,
            entity_type TEXT NOT NULL,
            natural_key TEXT NOT NULL,
            data_json TEXT NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(language_id, entity_type, natural_key)
          );
          CREATE TABLE IF NOT EXISTS entity_links (
            parent_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            relationship TEXT NOT NULL,
            child_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(parent_id, relationship, child_id)
          );
          CREATE INDEX IF NOT EXISTS entity_links_child ON entity_links(child_id);
          CREATE TABLE IF NOT EXISTS makes (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            display_name TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS vehicle_years (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            make_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            year INTEGER NOT NULL, UNIQUE(make_entity_id, year)
          );
          CREATE TABLE IF NOT EXISTS vehicle_models (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            make_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            year_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            year INTEGER NOT NULL, name TEXT NOT NULL, display_name TEXT NOT NULL,
            UNIQUE(make_entity_id, year_entity_id, display_name)
          );
          CREATE TABLE IF NOT EXISTS engines (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            vehicle_model_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            carcode TEXT NOT NULL, description TEXT NOT NULL, href TEXT,
            UNIQUE(vehicle_model_id, carcode)
          );
          CREATE INDEX IF NOT EXISTS vehicle_years_make ON vehicle_years(make_entity_id, year);
          CREATE INDEX IF NOT EXISTS vehicle_models_make_year ON vehicle_models(make_entity_id, year);
          CREATE INDEX IF NOT EXISTS engines_vehicle_model ON engines(vehicle_model_id);
          CREATE TABLE IF NOT EXISTS part_categories (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            name TEXT NOT NULL, display_name TEXT NOT NULL, group_name TEXT NOT NULL, href TEXT
          );
          CREATE TABLE IF NOT EXISTS parts (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            part_number TEXT NOT NULL, name TEXT NOT NULL, display_name TEXT NOT NULL,
            brand TEXT, price TEXT, url TEXT, image_url TEXT, info_url TEXT, video_url TEXT,
            UNIQUE(entity_id, part_number)
          );
          CREATE TABLE IF NOT EXISTS vehicle_category_parts (
            engine_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            category_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            part_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(engine_entity_id, category_entity_id, part_entity_id)
          );
          CREATE INDEX IF NOT EXISTS vehicle_category_parts_part ON vehicle_category_parts(part_entity_id);
          CREATE INDEX IF NOT EXISTS parts_number ON parts(part_number);
          CREATE TABLE IF NOT EXISTS query_sets (
            id INTEGER PRIMARY KEY,
            cache_key TEXT NOT NULL,
            language_id INTEGER NOT NULL REFERENCES languages(id) ON DELETE CASCADE,
            operation TEXT NOT NULL,
            arguments_json TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            accessed_at REAL NOT NULL,
            hits INTEGER NOT NULL DEFAULT 0,
            UNIQUE(language_id, cache_key)
          );
          CREATE INDEX IF NOT EXISTS query_sets_language_expiry ON query_sets(language_id, expires_at);
          CREATE TABLE IF NOT EXISTS query_set_entities (
            query_set_id INTEGER NOT NULL REFERENCES query_sets(id) ON DELETE CASCADE,
            entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(query_set_id, entity_id)
          );
          CREATE TABLE IF NOT EXISTS cache_entries (
            cache_key TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            created_at REAL NOT NULL,
            accessed_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            hits INTEGER NOT NULL DEFAULT 0
          );
          CREATE INDEX IF NOT EXISTS cache_entries_expiry ON cache_entries(expires_at);
        SQL
        db.execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, ?)", [Time.now.to_f])
      end
    end

    def read(key, language: "en")
      now = Time.now.to_f
      result = nil
      with_db do |db|
        row = db.get_first_row("SELECT id, expires_at FROM query_sets WHERE cache_key = ? AND language_id = (SELECT id FROM languages WHERE code = ?)", [key, language.to_s.downcase])
        if row && row[1].to_f > now
          root_id = db.get_first_value("SELECT entity_id FROM query_set_entities WHERE query_set_id = ? ORDER BY ordinal LIMIT 1", [row[0]])
          db.execute("UPDATE query_sets SET accessed_at = ?, hits = hits + 1 WHERE cache_key = ? AND language_id = (SELECT id FROM languages WHERE code = ?)", [now, key, language.to_s.downcase])
          result = hydrate_result(db, root_id) if root_id
        elsif row
          db.execute("DELETE FROM query_sets WHERE cache_key = ? AND language_id = (SELECT id FROM languages WHERE code = ?)", [key, language.to_s.downcase])
          prune_orphan_entities(db)
        end
      end
      result
    end

    def write(key, value, ttl_hours:, language: "en", operation: "unknown", arguments: [])
      now = Time.now.to_f
      with_db do |db|
        db.transaction do
          lang_code = language.to_s.downcase
          db.execute("INSERT OR IGNORE INTO languages(code) VALUES(?)", [lang_code])
          lang_id = db.get_first_value("SELECT id FROM languages WHERE code = ?", [lang_code]).to_i
          db.execute("INSERT INTO query_sets (cache_key, language_id, operation, arguments_json, fetched_at, expires_at, accessed_at, hits) VALUES (?, ?, ?, ?, ?, ?, ?, 0) ON CONFLICT(language_id, cache_key) DO UPDATE SET operation=excluded.operation, arguments_json=excluded.arguments_json, fetched_at=excluded.fetched_at, expires_at=excluded.expires_at, accessed_at=excluded.accessed_at, hits=0",
                     [key, lang_id, operation.to_s, JSON.generate(CacheCodec.encode(arguments)), now, now + ttl_hours * 3600, now])
          query_id = db.get_first_value("SELECT id FROM query_sets WHERE cache_key = ? AND language_id = ?", [key, lang_id]).to_i
          db.execute("DELETE FROM query_set_entities WHERE query_set_id = ?", [query_id])
          entity_ids = persist_result(db, value, language.to_s.downcase)
          entity_ids.each_with_index do |entity_id, ordinal|
            db.execute("INSERT OR IGNORE INTO query_set_entities(query_set_id, entity_id, ordinal) VALUES(?, ?, ?)", [query_id, entity_id, ordinal])
          end
          excess = db.get_first_value("SELECT COUNT(*) FROM query_sets").to_i - @max_entries
          db.execute("DELETE FROM query_sets WHERE id IN (SELECT id FROM query_sets ORDER BY accessed_at ASC LIMIT ?)", [excess]) if excess.positive?
          prune_orphan_entities(db)
        end
      end
    end

    def stats
      with_db do |db|
        row = db.get_first_row("SELECT COUNT(*), COALESCE(SUM(hits), 0) FROM query_sets")
        { entries: row[0].to_i, hits: row[1].to_i, path: path }
      end
    end

    def clear
      with_db do |db|
        count = db.get_first_value("SELECT COUNT(*) FROM query_sets").to_i
        db.execute("DELETE FROM query_sets")
        prune_orphan_entities(db)
        count
      end
    end

    def clear_expired
      with_db do |db|
        db.execute("DELETE FROM query_sets WHERE expires_at <= ?", [Time.now.to_f])
        count = db.changes
        prune_orphan_entities(db)
        count
      end
    end

    private

    def persist_result(db, value, language)
      lang_id = db.get_first_value("SELECT id FROM languages WHERE code = ?", [language]).to_i
      root_id = persist_entity(db, lang_id, "result", "#{value.class.name}:#{Digest::SHA256.hexdigest(CacheCodec.dump(value))}", root_model(value))
      case value
      when VehicleMakes
        CacheCodec.raw_attributes(value)[:makes].each_with_index do |name, i|
          id = persist_entity(db, lang_id, "make", name.to_s.downcase, { name: name })
          db.execute("INSERT INTO makes(entity_id, name, display_name) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name", [id, name, name])
          link_entity(db, root_id, "makes", id, i)
        end
      when VehicleYears
        raw_make = CacheCodec.raw_attributes(value)[:make]
        make_id = persist_entity(db, lang_id, "make", raw_make.to_s.downcase, { name: raw_make })
        db.execute("INSERT INTO makes(entity_id, name, display_name) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name", [make_id, raw_make, raw_make])
        link_entity(db, root_id, "make", make_id, 0)
        value.years.each_with_index do |year, i|
          id = persist_entity(db, lang_id, "year", "#{raw_make.downcase}:#{year}", { make: raw_make, year: year })
          db.execute("INSERT INTO vehicle_years(entity_id, make_entity_id, year) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET make_entity_id=excluded.make_entity_id, year=excluded.year", [id, make_id, year])
          link_entity(db, make_id, "years", id, i)
          link_entity(db, root_id, "years", id, i)
        end
      when VehicleModels
        raw_attrs = CacheCodec.raw_attributes(value)
        raw_make = raw_attrs[:make]
        raw_models = raw_attrs[:models]
        make_id = persist_entity(db, lang_id, "make", raw_make.to_s.downcase, { name: raw_make })
        db.execute("INSERT INTO makes(entity_id, name, display_name) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name", [make_id, raw_make, raw_make])
        link_entity(db, root_id, "make", make_id, 0)
        raw_models.each_with_index do |name, i|
          natural = "#{raw_make.downcase}:#{value.year}:#{name.downcase}"
          id = persist_entity(db, lang_id, "vehicle_model", natural, { make: raw_make, year: value.year, name: name })
          year_id = persist_year(db, lang_id, make_id, raw_make, value.year)
          db.execute("INSERT INTO vehicle_models(entity_id, make_entity_id, year_entity_id, year, name, display_name) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET make_entity_id=excluded.make_entity_id, year_entity_id=excluded.year_entity_id, year=excluded.year, name=excluded.name, display_name=excluded.display_name", [id, make_id, year_id, value.year, name, name])
          link_entity(db, make_id, "years", year_id, 0)
          link_entity(db, year_id, "models", id, i)
          link_entity(db, root_id, "models", id, i)
        end
      when VehicleEngines
        raw_attrs = CacheCodec.raw_attributes(value)
        raw_make = raw_attrs[:make]
        raw_model = raw_attrs[:model]
        model_id = vehicle_model_id(db, lang_id, raw_make, value.year, raw_model)
        raw_attrs[:engines].each_with_index do |engine, i|
          engine_attrs = CacheCodec.raw_attributes(engine)
          id = persist_entity(db, lang_id, "engine", "#{raw_make.downcase}:#{value.year}:#{raw_model.downcase}:#{engine.carcode}", engine)
          db.execute("INSERT INTO engines(entity_id, vehicle_model_id, carcode, description, href) VALUES(?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET vehicle_model_id=excluded.vehicle_model_id, carcode=excluded.carcode, description=excluded.description, href=excluded.href",
                     [id, model_id, engine.carcode, engine_attrs[:description], engine.href])
          link_entity(db, root_id, "vehicle_model", model_id, 0)
          link_entity(db, model_id, "engines", id, i)
          link_entity(db, root_id, "engines", id, i)
        end
      when VehiclePartCategories
        raw_attrs = CacheCodec.raw_attributes(value)
        model_id = vehicle_model_id(db, lang_id, raw_attrs[:make], value.year, raw_attrs[:model])
        raw_attrs[:categories].each_with_index do |category, i|
          id = persist_category(db, lang_id, category)
          link_entity(db, root_id, "categories", id, i)
          db.execute("INSERT OR IGNORE INTO entity_links(parent_id, relationship, child_id, ordinal) VALUES(?, 'vehicle_categories', ?, ?)", [model_id, id, i])
        end
      when VehiclePartsResult
        raw_attrs = CacheCodec.raw_attributes(value)
        raw_make = raw_attrs[:make]
        raw_model = raw_attrs[:model]
        model_id = vehicle_model_id(db, lang_id, raw_make, value.year, raw_model)
        engine_id = persist_entity(db, lang_id, "engine", "#{raw_make.downcase}:#{value.year}:#{raw_model.downcase}:#{value.carcode}", { carcode: value.carcode })
        db.execute("INSERT INTO engines(entity_id, vehicle_model_id, carcode, description, href) VALUES(?, ?, ?, '', NULL) ON CONFLICT(entity_id) DO UPDATE SET vehicle_model_id=excluded.vehicle_model_id, carcode=excluded.carcode", [engine_id, model_id, value.carcode])
        raw_category = raw_attrs[:category]
        category = PartCategory.new(name: raw_category, group_name: raw_category)
        category_id = persist_category(db, lang_id, category)
        link_entity(db, root_id, "vehicle_model", model_id, 0)
        link_entity(db, model_id, "engines", engine_id, 0)
        db.execute("DELETE FROM vehicle_category_parts WHERE engine_entity_id = ? AND category_entity_id = ?", [engine_id, category_id])
        raw_attrs[:parts].each_with_index do |part, i|
          part_id = persist_part(db, lang_id, part)
          link_entity(db, root_id, "parts", part_id, i)
          db.execute("INSERT OR IGNORE INTO vehicle_category_parts(engine_entity_id, category_entity_id, part_entity_id, ordinal) VALUES(?, ?, ?, ?)", [engine_id, category_id, part_id, i])
        end
        link_entity(db, root_id, "vehicle", model_id, 0)
      when PartSearchResult
        CacheCodec.raw_attributes(value)[:parts].each_with_index { |part, i| link_entity(db, root_id, "parts", persist_part(db, lang_id, part), i) }
      when PartBrands
        value.brands.each_with_index { |item, i| link_entity(db, root_id, "brands", persist_child_model(db, lang_id, item), i) }
      when ManufacturerOptions
        value.manufacturers.each_with_index { |item, i| link_entity(db, root_id, "manufacturers", persist_child_model(db, lang_id, item), i) }
      when PartGroupOptions
        value.part_groups.each_with_index { |item, i| link_entity(db, root_id, "part_groups", persist_child_model(db, lang_id, item), i) }
      when PartTypeOptions
        value.part_types.each_with_index { |item, i| link_entity(db, root_id, "part_types", persist_child_model(db, lang_id, item), i) }
      when WhatIsPartCalledResults
        value.results.each_with_index { |item, i| link_entity(db, root_id, "results", persist_child_model(db, lang_id, item), i) }
      end
      [root_id]
    end

    def root_model(value)
      return value unless value.is_a?(Model)

      data = CacheCodec.raw_attributes(value)
      data.each { |key, item| data[key] = [] if item.is_a?(Array) }
      value.class.new(**data)
    end

    def persist_child_model(db, language_id, model)
      natural = if model.respond_to?(:part_number)
                  model.part_number.to_s
                elsif model.respond_to?(:slug)
                  model.slug.to_s
                elsif model.respond_to?(:value)
                  model.value.to_s
                elsif model.respond_to?(:full_path)
                  model.full_path.to_s
                else
                  Digest::SHA256.hexdigest(CacheCodec.dump(model))
                end
      persist_entity(db, language_id, model.class.name.split("::").last, natural, model)
    end

    def hydrate_result(db, entity_id)
      row = db.get_first_row("SELECT data_json FROM entities WHERE id = ?", [entity_id])
      return nil unless row

      model = CacheCodec.load(row[0])
      return model unless model.is_a?(Model)

      fields = {
        "VehicleMakes" => [[:makes, "makes"]],
        "VehicleYears" => [[:years, "years"]],
        "VehicleModels" => [[:models, "models"]],
        "VehicleEngines" => [[:engines, "engines"]],
        "VehiclePartCategories" => [[:categories, "categories"]],
        "VehiclePartsResult" => [[:parts, "parts"]],
        "PartSearchResult" => [[:parts, "parts"]],
        "PartBrands" => [[:brands, "brands"]],
        "ManufacturerOptions" => [[:manufacturers, "manufacturers"]],
        "PartGroupOptions" => [[:part_groups, "part_groups"]],
        "PartTypeOptions" => [[:part_types, "part_types"]],
        "WhatIsPartCalledResults" => [[:results, "results"]]
      }
      fields.fetch(model.class.name.split("::").last, []).each do |attribute, relationship|
        child_rows = db.execute("SELECT e.data_json FROM entity_links l JOIN entities e ON e.id = l.child_id WHERE l.parent_id = ? AND l.relationship = ? ORDER BY l.ordinal", [entity_id, relationship])
        children = child_rows.map do |child_row|
          child = CacheCodec.load(child_row[0])
          child.is_a?(Hash) ? (child[:name] || child[:year] || child["name"] || child["year"]) : child
        end
        data = model.to_h
        data[attribute] = children
        model = model.class.new(**data)
      end
      model
    end

    def persist_entity(db, language_id, type, natural_key, data)
      db.execute("INSERT INTO entities(language_id, entity_type, natural_key, data_json, updated_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(language_id, entity_type, natural_key) DO UPDATE SET data_json=excluded.data_json, updated_at=excluded.updated_at",
                 [language_id, type, natural_key.to_s, CacheCodec.dump(data), Time.now.to_f])
      db.get_first_value("SELECT id FROM entities WHERE language_id = ? AND entity_type = ? AND natural_key = ?", [language_id, type, natural_key.to_s]).to_i
    end

    def link_entity(db, parent_id, relationship, child_id, ordinal)
      db.execute("INSERT OR REPLACE INTO entity_links(parent_id, relationship, child_id, ordinal) VALUES(?, ?, ?, ?)", [parent_id, relationship, child_id, ordinal])
    end

    def prune_orphan_entities(db)
      db.execute_batch(<<~SQL)
        WITH RECURSIVE reachable(id) AS (
          SELECT entity_id FROM query_set_entities
          UNION
          SELECT links.child_id FROM entity_links AS links
          INNER JOIN reachable ON links.parent_id = reachable.id
        )
        DELETE FROM entities WHERE id NOT IN (SELECT id FROM reachable);
      SQL
    end

    def vehicle_model_id(db, language_id, make, year, model)
      make_id = persist_entity(db, language_id, "make", make.to_s.downcase, { name: make })
      db.execute("INSERT INTO makes(entity_id, name, display_name) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name", [make_id, make, make])
      natural = "#{make.to_s.downcase}:#{year}:#{model.to_s.downcase}"
      id = persist_entity(db, language_id, "vehicle_model", natural, { make: make, year: year, name: model })
      year_id = persist_year(db, language_id, make_id, make, year)
      db.execute("INSERT INTO vehicle_models(entity_id, make_entity_id, year_entity_id, year, name, display_name) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET make_entity_id=excluded.make_entity_id, year_entity_id=excluded.year_entity_id, year=excluded.year, name=excluded.name, display_name=excluded.display_name", [id, make_id, year_id, year, model, model])
      link_entity(db, id, "make", make_id, 0)
      link_entity(db, id, "year", year_id, 0)
      link_entity(db, make_id, "years", year_id, 0)
      id
    end

    def persist_year(db, language_id, make_id, make, year)
      id = persist_entity(db, language_id, "year", "#{make.to_s.downcase}:#{year}", { make: make, year: year })
      db.execute("INSERT INTO vehicle_years(entity_id, make_entity_id, year) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET make_entity_id=excluded.make_entity_id, year=excluded.year", [id, make_id, year])
      link_entity(db, id, "make", make_id, 0)
      id
    end

    def persist_category(db, language_id, category)
      id = persist_entity(db, language_id, "part_category", category.group_name.to_s.downcase, category)
      raw_name = CacheCodec.raw_attributes(category)[:name]
      db.execute("INSERT INTO part_categories(entity_id, name, display_name, group_name, href) VALUES(?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name, group_name=excluded.group_name, href=excluded.href", [id, raw_name, raw_name, category.group_name, category.href])
      id
    end

    def persist_part(db, language_id, part)
      number = part.part_number.to_s
      brand = part.brand.to_s
      # A part number is not globally unique on AutoFactsDB: the same number can
      # be sold by several brands (e.g. 510073 from ACDelco, National, Timken).
      # Key by the part's canonical URL (brand + number) so distinct listings are
      # preserved through a cached read.
      natural = if part.url && !part.url.to_s.empty?
                  part.url.to_s
                elsif !number.empty?
                  "#{brand.downcase}:#{number.downcase}"
                else
                  Digest::SHA256.hexdigest(CacheCodec.dump(part))
                end
      id = persist_entity(db, language_id, "part", natural, part)
      raw_name = CacheCodec.raw_attributes(part)[:name]
      db.execute("INSERT INTO parts(entity_id, part_number, name, display_name, brand, price, url, image_url, info_url, video_url) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET part_number=excluded.part_number, name=excluded.name, display_name=excluded.display_name, brand=excluded.brand, price=excluded.price, url=excluded.url, image_url=excluded.image_url, info_url=excluded.info_url, video_url=excluded.video_url",
                 [id, number, raw_name, raw_name, part.brand, part.price, part.url, part.image_url, part.info_url, part.video_url])
      id
    end

    def language_for(db, language_id)
      db.get_first_value("SELECT code FROM languages WHERE id = ?", [language_id]) || "en"
    end

    def with_db
      db = SQLite3::Database.new(path)
      db.busy_timeout = 5000
      db.execute("PRAGMA foreign_keys = ON")
      yield db
    ensure
      db&.close
    end
  end

  # Decorates selected public read methods without changing their return types.
  module PersistentClientCache
    TTL_METHODS = {
      get_manufacturers: :dropdown_cache_hours,
      get_part_brands: :dropdown_cache_hours
    }.freeze
    CACHED_METHODS = %i[
      get_makes get_years_for_make get_models_for_make_year get_engines_for_vehicle get_vehicle
      get_part_categories get_parts_by_category
      get_manufacturers search_parts_by_number
      get_part_brands get_brand_parts
    ].freeze

    CACHED_METHODS.each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        store = @result_cache
        cacheable = method_name != :get_vehicle
        unless cacheable && @cache_config.enabled && store && @cache_backend == :sqlite
          return super(*args, **kwargs, &block)
        end

        key_data = JSON.generate([method_name, language, CacheCodec.encode(args), CacheCodec.encode(kwargs)])
        key = "v2:#{Digest::SHA256.hexdigest(key_data)}"
        cached = store.read(key, language: language)
        return cached unless cached.nil?

        result = super(*args, **kwargs, &block)
        ttl_setting = PersistentClientCache::TTL_METHODS[method_name]
        ttl = if ttl_setting
                @dropdown_cache_hours
              elsif method_name == :get_parts_by_category
                @cache_config.part_ttl_hours
              elsif %i[search_parts_by_number get_brand_parts].include?(method_name)
                @cache_config.result_ttl_hours
              else
                @dropdown_cache_hours
              end
        store.write(key, result, ttl_hours: ttl, language: language,
                    operation: method_name, arguments: [args, kwargs]) unless result.nil?
        result
      end
    end
  end
end
