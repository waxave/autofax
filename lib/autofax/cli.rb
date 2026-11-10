# frozen_string_literal: true

require "json"
require "optparse"

module Autofax
  # Command-line interface for the Autofax client.
  module CLI
    module_function

    GLOBAL_OPTIONS = { json: false, language: "en", display: :original, cache_backend: :sqlite, cache_path: nil, enable_caching: true }.freeze

    def main(argv = ARGV, out: $stdout, err: $stderr, input: $stdin, client_factory: ->(options) { Client.new(**options) })
      args = argv.dup
      options = GLOBAL_OPTIONS.dup
      OptionParser.new do |parser|
        parser.on("--json", "Output machine-readable JSON") { options[:json] = true }
        parser.on("--language CODE", "Language code (accepted for compatibility; AutoFactsDB is English-only)") { |value| options[:language] = value }
        parser.on("--display MODE", %w[original transformed], "Display text mode (default: original)") { |value| options[:display] = value.to_sym }
        parser.on("--cache-backend BACKEND", %w[sqlite memory], "Cache backend (default: sqlite)") { |value| options[:cache_backend] = value.to_sym }
        parser.on("--cache-path PATH", "SQLite cache database path") { |value| options[:cache_path] = value }
        parser.on("--no-cache", "Disable caching for this invocation") { options[:enable_caching] = false }
        parser.on("-h", "--help", "Show help") { out.puts(help); return 0 }
      end.order!(args)

      return legacy_search(args, options, out, err, client_factory) if legacy_invocation?(args)
      return command_help(out) if args.empty? || %w[help --help].include?(args.first)

      command = args.shift
      command_options = {}
      if command == "search"
        parser = OptionParser.new do |opts|
          opts.on("--manufacturer NAME") { |v| command_options[:manufacturer] = v }
          opts.on("--part-group NAME") { |v| command_options[:part_group] = v }
          opts.on("--part-type NAME") { |v| command_options[:part_type] = v }
          opts.on("--part-name NAME") { |v| command_options[:part_name] = v }
        end
        parser.parse!(args)
      elsif command == "categories" || command == "parts"
        parser = OptionParser.new do |opts|
          opts.on("--carcode CODE") { |v| command_options[:carcode] = v }
          opts.on("--engine-index N", Integer) { |v| command_options[:engine_index] = v }
        end
        parser.parse!(args)
      end

      client_options = options.slice(:language, :display, :cache_backend, :cache_path, :enable_caching)
      client = client_factory.call(client_options)
      result = nil
      client.with do |session|
        result = execute_command(session, command, args, command_options)
      end
      print_result(result, options[:json], out)
      0
    rescue OptionParser::ParseError, ArgumentError, Autofax::Error => e
      err.puts("autofax: #{e.message}")
      err.puts("Run 'autofax help' for usage.")
      1
    rescue Interrupt
      err.puts("autofax: cancelled")
      130
    end

    def execute_command(client, command, args, opts)
      case command
      when "makes" then no_args!(args); client.get_makes
      when "years" then require_args!(args, 1); client.get_years_for_make(args[0])
      when "models" then require_args!(args, 2); client.get_models_for_make_year(args[0], Integer(args[1]))
      when "engines" then require_args!(args, 3); client.get_engines_for_vehicle(args[0], Integer(args[1]), args[2])
      when "vehicle"
        require_args!(args, 3); client.get_vehicle(args[0], Integer(args[1]), args[2], engine_index: opts.fetch(:engine_index, 0))
      when "categories"
        if opts[:carcode]
          no_args!(args); client.search_parts(opts[:carcode])
        else
          require_args!(args, 3); client.get_vehicle(args[0], Integer(args[1]), args[2], engine_index: opts.fetch(:engine_index, 0)).get_part_categories
        end
      when "parts"
        require_args!(args, opts[:carcode] ? 1 : 4)
        if opts[:carcode]
          raise ArgumentError, "use 'categories --carcode' to look up categories directly"
        end
        vehicle = client.get_vehicle(args[0], Integer(args[1]), args[2], engine_index: opts.fetch(:engine_index, 0))
        vehicle.get_parts_by_category(args[3])
      when "subcategory"
        require_args!(args, 4); client.get_individual_parts_from_subcategory(args[0], args[1], args[2], args[3])
      when "manufacturers" then no_args!(args); client.get_manufacturers
      when "part-groups" then no_args!(args); client.get_part_groups
      when "part-types" then no_args!(args); client.get_part_types
      when "brands" then no_args!(args); client.get_part_brands
      when "brand" then require_args!(args, 1); client.get_brand_parts(args[0])
      when "part" then require_args!(args, 2); client.get_part(args[0], args[1])
      when "search"
        require_args!(args, 1); client.search_parts_by_number(args[0], **opts)
      when "part-name" then require_args!(args, 1); client.what_is_part_called(args.join(" "))
      when "tools"
        no_args!(args); client.get_tool_categories
      when "orders"
        require_args!(args, 2); client.lookup_order_status(args[0], args[1])
      when "account"
        no_args!(args); client.get_account_activity
      when "cache"
        operation = args.shift or raise ArgumentError, "expected cache operation"
        no_args!(args)
        case operation
        when "stats" then client.cache_stats
        when "clear" then client.clear_all_caches
        when "clear-expired" then client.clear_expired_caches
        when "clear-search" then client.clear_parts_search_cache; { cleared: true }
        else raise ArgumentError, "unknown cache operation: #{operation}"
        end
      else
        raise ArgumentError, "unknown command: #{command}"
      end
    end

    def legacy_invocation?(args)
      args.length >= 3 && !%w[makes years models engines vehicle categories parts subcategory manufacturers part-groups part-types brands brand part search part-name tools orders account cache].include?(args.first)
    end

    def legacy_search(args, options, out, err, client_factory)
      make, year, model, category = args
      raise ArgumentError, "year must be an integer" unless year.match?(/\A\d+\z/)
      client = client_factory.call(options.slice(:language, :display, :cache_backend, :cache_path, :enable_caching))
      result = client.with do |session|
        vehicle = session.get_vehicle(make, year.to_i, model)
        categories = vehicle.get_part_categories
        if category
          match = categories.categories.find { |item| item.name.downcase.include?(category.downcase) }
          raise ArgumentError, "category '#{category}' not found" unless match
          vehicle.get_parts_by_category(match.group_name)
        else
          categories
        end
      end
      print_result(result, options[:json], out)
      0
    rescue Autofax::Error, ArgumentError => e
      err.puts("autofax: #{e.message}")
      1
    end

    def require_args!(args, count)
      raise ArgumentError, "expected at least #{count} argument(s)" if args.length < count
    end

    def no_args!(args)
      raise ArgumentError, "unexpected arguments: #{args.join(' ')}" unless args.empty?
    end

    def serialize(value)
      case value
      when Array then value.map { |item| serialize(item) }
      when Hash then value.transform_values { |item| serialize(item) }
      when Autofax::Model then value.to_h.transform_values { |item| serialize(item) }
      when Autofax::Vehicle then { make: value.make, year: value.year, model: value.model, engine: serialize(value.engine), carcode: value.carcode }
      when Symbol then value.to_s
      else value
      end
    end

    def print_result(value, json, out)
      out.puts(JSON.pretty_generate(serialize(value)))
    end

    def command_help(out)
      out.puts(help)
      0
    end

    def help
      <<~TEXT
        Usage: autofax [--json] [--language CODE] [--display original|transformed]
                        [--cache-backend sqlite|memory]
                        [--cache-path PATH] [--no-cache] COMMAND [ARGS] [OPTIONS]

        Vehicle catalog:
          makes | years MAKE | models MAKE YEAR | engines MAKE YEAR MODEL
          vehicle MAKE YEAR MODEL [--engine-index N]
          categories MAKE YEAR MODEL [--engine-index N]
          parts MAKE YEAR MODEL CATEGORY [--engine-index N]

        Part search:
          manufacturers | brands | brand BRAND_SLUG | part BRAND_SLUG PART_NUMBER
          search NUMBER [--manufacturer NAME] [--part-name NAME]

        Other:
          cache stats|clear|clear-expired|clear-search

        SQLite caching is persistent by default; use --cache-backend memory or
        --no-cache to change it for this invocation.
        AutoFactsDB already returns display text, so --display original and
        --display transformed produce the same output; the flag is accepted for
        Punkauto compatibility.
        Legacy syntax remains supported: autofax MAKE YEAR MODEL [CATEGORY]

        RockAuto-only commands (tools, orders, account, part-groups, part-types,
        part-name, subcategory, categories --carcode) are accepted for API
        compatibility but raise a "not supported" error on AutoFactsDB.
      TEXT
    end
  end
end
