# Changelog

## [0.1.0] - 2026-11-09

- Initial release.
- Punkauto-compatible public API and CLI for AutoFactsDB.com.
- Vehicle catalog: makes, years, models, engines, part categories, and parts.
- Part search by number, part brands, brand parts, and per-part fitment guides.
- Persistent SQLite and in-memory result caching with display modes.
- Explicit `Autofax::NotSupportedError` for RockAuto-only features (orders,
  accounts, login, and tools).
