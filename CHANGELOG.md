# Changelog

All notable changes to this QuickApp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Login to the inverter's local REST API as plant owner.
- Process data, settings and device information as QuickApp variables,
  selected with `readValues` and `writeValues`.
- `set` action and two-way synchronisation of settings; changes made on the
  inverter take precedence.
- Optional child devices (`childValues`) with stable device IDs.
- Value table in the user interface with names in English, German, French
  and Italian, and units.
- Built-in energy meter icon instead of the generic device icon.

[Unreleased]: https://github.com/schopf16/fibaro-qa-plenticore/commits/main
