# Autofax

A Ruby API client for [AutoFactsDB.com](https://autofactsdb.com) — an
independent OEM & aftermarket parts fitment catalog. Autofax talks to
AutoFactsDB's HTML catalog directly and returns structured Ruby objects, so
you get brand, manufacturer part number, and engine-level fitment instead of
scraping search results.

Autofax is **API- and CLI-compatible with [punkauto](https://github.com/waxave/punkauto)**
(the RockAuto.com client). The vehicle-catalog surface — makes → years →
models → engines → categories → parts — uses the same method names, model
types, and CLI commands, so the two gems are drop-in replacements for that
shared surface.

- **Vehicle lookup chain** — makes → years → models → engines → parts
- **Part search** — search by part number or keyword
- **Part brands** — browse the catalog by manufacturer
- **Part detail** — per-part fitment guide (year / make / model / engine)

## Installation

Add this line to your application's `Gemfile`:

```ruby
gem "autofax"
```

To use it straight from the repository:

```ruby
gem "autofax", github: "waxave/autofax"
```

Then run:

```sh
bundle install
```

## Quick start

```ruby
require "autofax"

Autofax::Client.new.with do |client|
  vehicle = client.get_vehicle("Toyota", 2020, "Camry")
  puts "Vehicle: #{vehicle.year} #{vehicle.make} #{vehicle.model}"

  brake_parts = vehicle.get_parts_by_category("Brake & Wheel Hub")
  puts "Found #{brake_parts.count} brake components"

  brake_parts.parts.first(3).each do |part|
    puts "- #{part.brand} #{part.part_number}"
  end
end
```

`Client#with` guarantees the HTTP session is closed when the block ends. You
can also manage the session manually with `client.close`.

## Configuration

```ruby
client = Autofax::Client.new(
  enable_caching: true,
  part_cache_hours: 12,
  search_cache_hours: 12,
  dropdown_cache_hours: 24,
  max_cached_parts: 1000,
  max_cached_searches: 100,
  cache_backend: :sqlite,     # :sqlite (persistent, default) or :memory
  cache_path: "./autofax.sqlite3", # optional; defaults under XDG cache dir
  display: :original          # accepted for Punkauto compatibility; no effect
)
```

| Option | Default | Description |
|---|---|---|
| `enable_caching` | `true` | Enable result caching |
| `part_cache_hours` | `12` | Expiry (hours) for cached vehicle-part results |
| `search_cache_hours` | `12` | Expiry (hours) for cached search and brand results |
| `dropdown_cache_hours` | `24` | Expiry (hours) for catalog and dropdown results |
| `max_cached_parts` | `1000` | Cache capacity setting for part data |
| `max_cached_searches` | `100` | Cache capacity setting for search results |
| `cache_backend` | `:sqlite` | `:sqlite` shares cache across clients/processes; `:memory` is client-local |
| `cache_path` | `$XDG_CACHE_HOME/autofax/cache.sqlite3` or `~/.cache/autofax/cache.sqlite3` | SQLite location; override with `AUTOFAX_CACHE_PATH` |
| `display` | `:original` | Accepted for Punkauto compatibility. AutoFactsDB already returns display text, so `:original` and `:transformed` are identical |

For Rails, keep the writable database with the application, not inside the gem:

```ruby
Autofax::Client.new(
  cache_path: Rails.root.join("storage/autofax/cache.sqlite3").to_s
)
```

Add the chosen `storage/` path to `.gitignore`.

> **Language note:** `language:` and `use_mobile_profile:` are accepted for
> Punkauto compatibility. AutoFactsDB is English-only and serves the same HTML
> regardless of user agent, so those options have no effect on requests.
>
> **Display text note:** AutoFactsDB already serves properly-cased display text
> (`Honda`, `Civic`, `Brake & Wheel Hub`, `BMW`, `DENSO`). Autofax returns it
> verbatim and never re-cases it, so `display: :original` and
> `display: :transformed` produce identical results.

## Public API

### Vehicle lookup

```ruby
makes   = client.get_makes                       # => VehicleMakes
years   = client.get_years_for_make("Honda")     # => VehicleYears
models  = client.get_models_for_make_year("Honda", 2021)  # => VehicleModels
engines = client.get_engines_for_vehicle("Honda", 2021, "Civic") # => VehicleEngines
```

Each result exposes `count` plus its collection (`makes`, `years`, `models`,
`engines`).

`get_vehicle` resolves the engine and returns a scoped `Vehicle` object:

```ruby
vehicle = client.get_vehicle("Honda", 2021, "Civic")        # first engine
vehicle = client.get_vehicle("Honda", 2021, "Civic", engine_index: 2)
```

On AutoFactsDB the vehicle identifier is the **engine URL slug** (the analogue
of RockAuto's `carcode`):

```ruby
vehicle.carcode                         # => "15l-l4-turbocharged"
categories = vehicle.get_part_categories # => VehiclePartCategories
parts      = vehicle.get_parts_by_category("Brake & Wheel Hub") # => VehiclePartsResult
```

### Part search

```ruby
result = client.search_parts_by_number("90919-02230")
# Or pass an extra keyword/brand to narrow the full-text query:
result = client.search_parts_by_number("FL500S", manufacturer: "Motorcraft")
```

AutoFactsDB search is a single full-text query; `manufacturer:` and
`part_name:` are folded into that query, while `part_group:`/`part_type:` are
accepted but ignored (the site has no such dropdowns).

### Part brands

```ruby
brands = client.get_part_brands          # => PartBrands
brands.brand_by_name("denso")            # => PartBrand(slug: "denso", name: "DENSO")

parts = client.get_brand_parts("denso")  # => PartSearchResult
```

`get_manufacturers` is also available and maps the same brands to
`ManufacturerOptions` for Punkauto compatibility.

### Part detail (fitment guide)

```ruby
detail = client.get_part("holstein", "2ABS3508") # => PartDetail
detail.name                                   # => "ABS Wheel Speed Sensor"
detail.fitments.first                         # => Fitment(year, make, model, engine)
detail.notes                                  # => ["Includes Harness", ...]
```

## Unsupported RockAuto-only features

AutoFactsDB has no orders, accounts, login, or tools section. The public API
keeps the full Punkauto surface, but these methods raise
`Autofax::NotSupportedError`:

- **Tools** — `get_tool_categories`, `get_tools_by_category`
- **Orders** — `lookup_order_status`, `request_order_list`
- **Account** — `login`, `logout`, `get_saved_addresses`, `get_saved_vehicles`,
  `get_account_activity`, `get_order_history`, `add_external_order`
- **RockAuto-specific search** — `what_is_part_called`, `get_part_groups`,
  `get_part_types`, `search_parts` (carcode-only lookup),
  `get_individual_parts_from_subcategory` (subcategories are inline sections)

## Caching

```ruby
client.cache_stats            # => Hash of cache settings and statistics
client.clear_all_caches       # => Hash of what was cleared
client.clear_expired_caches   # => Hash of expired entry counts
client.clear_parts_search_cache # clears this client's dropdown objects

client.configure_cache(
  enable_caching: false,
  part_cache_hours: 24,
  max_cached_parts: 500
)
```

The default SQLite cache is a persistent, versioned relational database. Makes,
years, models, engines, part categories, parts, and brands are stored as linked
entities; cache hits are rebuilt as the existing Ruby model types. The default
file is `$XDG_CACHE_HOME/autofax/cache.sqlite3`, or `~/.cache/autofax/cache.sqlite3`
when `XDG_CACHE_HOME` is unset. Set `cache_path:` or `AUTOFAX_CACHE_PATH` to
choose a different file. The CLI shares the same SQLite cache by default.

Autofax returns AutoFactsDB's display text verbatim: makes and models keep the
site's casing (`Honda`, `Civic`, `BMW`, `GMC`), and brand names keep theirs
(`DENSO`, `ACDelco`). `display:` is accepted for Punkauto compatibility but is
a no-op, since the site already returns display text. This setting does not
affect cache keys or identifiers.

## Error handling

All errors subclass `Autofax::Error`:

```ruby
begin
  client.get_parts_by_category("Honda", 2021, "Civic", "15l-l4-turbocharged", "Brake & Wheel Hub")
rescue Autofax::NotSupportedError => e
  # operation has no AutoFactsDB equivalent
rescue Autofax::ApiError => e
  # a request or parse failed
rescue Autofax::Error => e
  # any other client error
end
```

## Data models

- **Vehicle** — `Engine`, `VehicleMakes`, `VehicleYears`, `VehicleModels`,
  `VehicleEngines`, `VehiclePartCategories`, `VehiclePartsResult`, `Vehicle`
- **Parts** — `PartInfo`, `PartCategory`, `PartSearchOption`,
  `ManufacturerOptions`, `PartGroupOptions`, `PartTypeOptions`,
  `PartSearchResult`, `WhatIsPartCalledResult`, `WhatIsPartCalledResults`
- **Brands** — `PartBrand`, `PartBrands`
- **Part detail** — `Fitment`, `PartDetail`
- **Compatibility** — `OrderItem`, `ShippingInfo`, `BillingInfo`, `OrderStatus`,
  `OrderStatusResult`, `SavedAddress`, `SavedVehicle`, `AccountActivityResult`,
  `ToolCategory`, `ToolInfo`, `ToolsResult`, and the pricing/cache helpers

## CLI

Run from an installed gem as `autofax ...`, or directly from a checkout with
`./exe/autofax ...`. Global options go before the command. Results are printed
as JSON; `--json` is accepted as an explicit output-mode flag.

```sh
autofax makes
autofax years Honda
autofax models Honda 2021
autofax engines Honda 2021 Civic
autofax vehicle Honda 2021 Civic --engine-index 1
autofax categories Honda 2021 Civic
autofax parts Honda 2021 Civic "Brake & Wheel Hub"

autofax manufacturers
autofax brands
autofax brand denso
autofax part holstein 2ABS3508
autofax search '90919-*' --manufacturer DENSO

autofax --json makes
autofax --display transformed makes
autofax --cache-path ./tmp/autofax.sqlite3 cache stats
autofax --cache-backend memory makes
autofax --no-cache makes

autofax cache stats
autofax cache clear-expired
autofax cache clear-search
autofax cache clear

# Backward-compatible shorthand:
autofax Honda 2021 Civic brake
```

Use `autofax help` for the complete command summary. `--language CODE`,
`--display original|transformed`, `--cache-backend sqlite|memory`,
`--cache-path PATH`, `--no-cache`, and `--json` are global options and should
appear before the command. The RockAuto-only commands (`tools`, `orders`,
`account`, `part-groups`, `part-types`, `part-name`, `subcategory`,
`categories --carcode`) are accepted for compatibility but exit with a clear
"not available on AutoFactsDB" error.

## Development

This repository uses [mise](https://mise.jdx.dev/) to select Ruby and run
project tasks. The pinned Ruby version is in `mise.toml`.

```sh
mise install          # install the configured Ruby version
mise run setup        # bundle install
mise run test         # full RSpec suite
mise run test:cli     # CLI specs only
mise run check        # Ruby syntax checks and full test suite
mise run build        # build autofax.gem
mise run release      # test, build, tag vX.Y.Z, and push branch + tag
mise run release:local # test, build, and tag locally without pushing
mise run release:gem  # release and publish the gem to RubyGems
```

Run `mise tasks` to list the available tasks. The equivalent direct test
commands are `bundle exec rspec` and `bundle exec rspec spec/cli_spec.rb`.

### Releasing

`mise run release` reads the version from `lib/autofax/version.rb`, runs the
suite, builds the gem, creates an annotated `vX.Y.Z` tag, and pushes the branch
and tag. Use `mise run release:local` to create the tag without pushing, or
`script/release --gem` to also `gem push`. The script refuses to run on a dirty
working tree or when the tag already exists.

Pushing a `v*` tag triggers `.github/workflows/release.yml`, which runs the
tests, publishes the gem to RubyGems (via the `RUBYGEMS_API_KEY` secret), and
creates a GitHub release with the built `.gem`. `.github/workflows/ci.yml` runs
the suite on every push to `main` and on pull requests.

### Fixtures

The test suite runs entirely offline. Real AutoFactsDB HTML pages are saved
under `spec/fixtures/` and stubbed with WebMock, so development and testing
never hit the network:

```sh
ls spec/fixtures/
# brand_denso.html  category_brake_and_wheel_hub.html  make_honda.html ...
```

To refresh a fixture after a site change, re-download the page once:

```sh
curl -sSL "https://autofactsdb.com/vehicles/honda/2021/civic/" \
  -o spec/fixtures/model_honda_2021_civic.html
```

## Disclaimer

This client is for educational and legitimate research purposes. Respect
AutoFactsDB.com's terms of service, implement appropriate rate limiting, and do
not abuse the service or scrape large datasets.
