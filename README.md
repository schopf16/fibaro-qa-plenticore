# KOSTAL PLENTICORE

Monitors and controls KOSTAL PLENTICORE and PIKO IQ inverters through their local REST API.

A QuickApp for the Fibaro Home Center 3.

> **Status:** in development - not yet released.

## Features

- ...

## Requirements

| | |
|---|---|
| Tested with | Fibaro Home Center 3, firmware 5.220.11 |
| Expected to work, untested | Home Center 3 Lite, Yubii Home |
| Network access | Local network only - no internet access |

## Installation

1. Download the latest `.fqa` from the [releases](https://github.com/schopf16/fibaro-qa-plenticore/releases)
   (or install it from the Fibaro marketplace).
2. In the HC3 web interface: **Settings → Devices → Add device → Other device →
   Upload file**, and select the `.fqa`.
3. Open the new QuickApp, go to **Variables**, and fill them in (see below).
   Until the configuration is valid, the QuickApp shows "Not configured".

## Configuration

| Variable | Default | Description |
|---|---|---|
| `pollIntervalSec` | `300` | Seconds between updates (30-86400) |
| `logLevel` | `info` | `error`, `warn`, `info` or `debug` |
| `language` | `auto` | UI language: `auto` (controller language), `en`, `de`, `fr`, `it` |

## Languages

The user interface is available in English, German, French and Italian and
follows the controller's language (override with the variable `language`).
French and Italian are not reviewed by a native speaker - [corrections are welcome](https://github.com/schopf16/fibaro-qa-plenticore/issues/new?template=translation.yml).

## Privacy

This QuickApp communicates only with devices in your local network. It does
not contact the internet, does not check for updates and sends no telemetry.
Credentials are stored in password-type variables and never written to the log.

## Troubleshooting

All log lines of this QuickApp carry the tag **`PLENTICORE`** - filter
the HC3 console by it.

1. Set the variable `logLevel` to `debug` and save (this restarts the QuickApp).
2. Reproduce the problem.
3. Copy the log from the line `KOSTAL PLENTICORE v... starting ...` to the problem.
4. Also look for `QUICKAPP<id>` lines with "QuickApp crashed" - they should
   never appear; if they do, please include them.
5. Before sharing, remove addresses and personal names, then open an
   [issue](https://github.com/schopf16/fibaro-qa-plenticore/issues/new?template=bug_report.yml).

## Support

- Questions and bugs: [GitHub issues](https://github.com/schopf16/fibaro-qa-plenticore/issues)
- Security issues: please report privately via
  [security advisories](https://github.com/schopf16/fibaro-qa-plenticore/security/advisories/new)

## License

[MIT](LICENSE)
