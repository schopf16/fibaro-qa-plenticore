# Changelog

All notable changes to this QuickApp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Switches and sliders in the user interface for settings listed in
  `writeValues`; settings without a control are changed with `set`, and the
  log says so at start.
- Option `deadband` to write values on every change instead of only on
  changes beyond 10 W, 0.01 kWh or 1 %.

### Changed

- All listed values are published in one QuickApp variable `values` (JSON)
  instead of one variable per value.
- `pollIntervalSec`, `logLevel` and `language` are options in `App.OPTIONS`
  at the top of the file `App` instead of QuickApp variables.
- Poll interval default 10 s instead of 30 s; minimum 5 s.
- New defaults for `readValues`, `writeValues` and `childValues`.
- Changing a setting in a QuickApp variable is replaced by the user
  interface controls and the `set` action.
- README: how-to with table of contents near the top, and a scene example
  for reading and writing values.

### Upgrade notes

- On the first start, the QuickApp removes the variables of 1.0.0 that it no
  longer uses (one per value, `pollIntervalSec`, `logLevel`, `language`) and
  restarts once. `host`, `password` and the three lists are kept.
- Scenes that read single variables such as `batterySoc` must read the
  variable `values` instead (see README, "Reading values").
- A changed poll interval, log level or language must be set again in
  `App.OPTIONS`.

## [1.0.0] - 2026-09-30

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
- The QuickApp stops with "Controller not supported" on a Lua without
  64-bit integers, which the inverter login requires.

[Unreleased]: https://github.com/schopf16/fibaro-qa-plenticore/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/schopf16/fibaro-qa-plenticore/releases/tag/v1.0.0
