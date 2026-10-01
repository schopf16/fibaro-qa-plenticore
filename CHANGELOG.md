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
- Option `https` (default on): encrypted connection to the inverter.

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

### Fixed

- Saving the code in the HC3 editor left the user interface without status
  line, refresh button or values: the editor rebuilds the layout from its own
  copy (viewLayout), which was not updated. The QuickApp now writes both and
  rebuilds the complete layout whenever it differs.
- A number outside the 64-bit integer range (`1e20`) or infinity for a
  setting raised a Lua error; it is now rejected with a clear message (#20).
- An error while processing a reading stopped polling for good; the next
  reading is now scheduled first (#20).
- A drop to zero inside the dead band was never published, so `pvPower`
  could stay at a few watts overnight (#21).
- The cleanup of 1.0.0 variables ran on every start and also deleted
  variables a user had created with a value name; it now runs once, removes
  only the variables 1.0.0 created, and restarts only if the controller kept
  the change (#22).

### Security

See advisory GHSA-rj7p-2wjf-cw8x. All points require access to the local
network.

- The login refuses a challenge with fewer than 10000 key derivation
  rounds; a device impersonating the inverter could otherwise obtain a proof
  that allows a fast offline password search.
- Nonces and the AES-GCM IV came from `math.random`, which the controller
  does not seed: they repeated after every restart. They now come from a
  SHA-256 pool seeded at start and mixed with the inverter's random values.
- The session ID was sent in clear text; the connection now uses HTTPS by
  default.
- Text received from the inverter is escaped before it is shown in the user
  interface.

### Upgrade notes

- On the first start, the QuickApp removes the variables of 1.0.0 that it no
  longer uses (one per value listed in `readValues` and `writeValues`,
  `pollIntervalSec`, `logLevel`, `language`) and restarts once. `host`,
  `password`, the three lists and all other variables are kept.
- The connection uses HTTPS. If an inverter does not offer it, set
  `https = false` in `App.OPTIONS`.
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
