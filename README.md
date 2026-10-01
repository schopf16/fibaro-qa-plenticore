# KOSTAL PLENTICORE

![KOSTAL PLENTICORE QuickApp for FIBARO Home Center 3](assets/marketplace/plenticore-marketplace-1420x1000.png)

A QuickApp for the Fibaro Home Center 3 that reads and writes KOSTAL
PLENTICORE and PIKO IQ inverters through their local REST API. Selected
values appear in the QuickApp's user interface and in one variable for
scenes, optionally as child devices, and battery settings can be changed
from the user interface, scenes and other QuickApps.

## Contents

- [How-to](#how-to)
  - [Step 1: Install](#step-1-install)
  - [Step 2: Fill in the variables](#step-2-fill-in-the-variables)
  - [Step 3: Options (optional)](#step-3-options-optional)
  - [Step 4: Check](#step-4-check)
- [Features](#features) · [Requirements](#requirements)
- [User interface](#user-interface) · [Reading values](#reading-values) ·
  [Writing values](#writing-values) · [Scene example](#scene-example) ·
  [Child devices](#child-devices)
- [Value reference](#value-reference): [measured values](#measured-values) ·
  [settings](#settings) · [device information](#device-information) ·
  [time control](#time-control)
- [Troubleshooting](#troubleshooting) · [Support](#support)

## How-to

### Step 1: Install

1. Download the latest `.fqa` from the [releases](https://github.com/schopf16/fibaro-qa-plenticore/releases).
2. In the HC3 web interface: **Settings → Devices → Add device → Other device →
   Upload file**, and select the `.fqa`.

### Step 2: Fill in the variables

Open the new QuickApp and go to **Variables**. Saving the variables restarts
the QuickApp - this is how the HC3 applies them.

| Variable | What to enter | Default |
|---|---|---|
| `host` | IP address or host name of the inverter in your network | *(empty, required)* |
| `password` | Password of the **plant owner** in the inverter's web interface | *(empty, required)* |
| `readValues` | Values to read and show: [measured values](#measured-values), [settings](#settings), [device information](#device-information) | `pvPower, homePower, gridPower, batteryPower, batterySoc, yieldDay, yieldTotal, homeFromGridTotal` |
| `writeValues` | [Settings](#settings) you want to change | `batteryMinSoc` |
| `childValues` | [Measured values](#measured-values) marked "Child: yes" that get their own device | `pvPower, gridPower, batteryPower, batterySoc, yieldTotal, homeFromGridTotal` |

- The three lists take names separated by commas, spelled exactly as in the
  [value reference](#value-reference); `none` means an empty list.
- An unknown name stops the QuickApp in the "not configured" state, and the
  log names it.
- A setting in `writeValues` is also read and shown; it does not need to be
  listed in `readValues` as well.
- The variable `values` is written by the QuickApp; leave it as it is (see
  [Reading values](#reading-values)).

### Step 3: Options (optional)

Options that rarely change are at the top of the file `App` in the
QuickApp's editor:

```lua
App.OPTIONS = {
  pollIntervalSec = 10,     -- seconds between two readings: 5 to 3600
  deadband        = true,   -- true: write values only when they change by more than
                            -- 10 W, 0.01 kWh or 1 %; false: on every change
  https           = true,   -- true: encrypted connection to the inverter (its self-signed
                            -- certificate is accepted); false: plain HTTP
  logLevel        = "info", -- "error", "warn", "info" or "debug" (for bug reports)
  language        = "auto", -- "auto" (controller language), "en", "de", "fr" or "it"
}
```

Change a value and save; the QuickApp restarts. An invalid value is reported
in the log and replaced by its default. Note your changes: installing a newer
version of the QuickApp replaces this file.

### Step 4: Check

The first login takes about 20 seconds. Then the status line shows the
current PV power and battery state of charge, and the table shows the listed
values. If not, see [Troubleshooting](#troubleshooting).

## Features

- Measured values (power, energy, battery) and settings in the user interface
  and in one JSON variable for scenes and other QuickApps
- Switches and sliders in the user interface for writable settings
- Changes made on the inverter (web interface, app) are taken over
- Optional child devices with stable IDs, including energy meters for the energy panel
- Login as plant owner: the password never leaves the HC3 in clear text
- Encrypted connection to the inverter (HTTPS)
- Local network only - no internet access
- User interface in English, German, French and Italian

## Requirements

| | |
|---|---|
| Tested with | FIBARO Home Center 3, firmware 5.220.11, and KOSTAL PLENTICORE plus 8.5 (G1), UI 01.30 |
| Not tested | All other controllers and inverters |
| Not possible | Home Center 2 and Home Center Lite: they do not run Home Center 3 QuickApps |
| Inverter access | IP address or host name and the **plant owner password** of the inverter's web interface |
| Network access | Local network only |

The login to the inverter computes SHA-256 and AES with 64-bit integers. On a
controller whose Lua has smaller integers, the QuickApp stops with the status
"Controller not supported" instead of computing wrong values. The inverter's
own API description names PIKO IQ and PLENTICORE plus; other KOSTAL models
may offer the same API, but this is not verified.

## User interface

The QuickApp shows a status line and a table with one row per value listed
in `readValues` and `writeValues`: the name in the selected language, and
the value with its unit, for example:

| | |
|---|---|
| PV-Leistung | 3120 W |
| Batterie-Ladestand | 64 % |
| PV-Ertrag heute | 12.4 kWh |
| Zeitsteuerung Montag | 11:45-12:00 (2) |

Settings listed in `writeValues` get a control: a **switch** beside the name
for on/off settings, a **slider** below the value for settings with a range.
The column "UI control" in the [settings](#settings) table shows which
settings have one; the others are changed with the `set` action (see
[Writing values](#writing-values)), and the log says so at start.

The QuickApp adds or removes table rows itself when the lists change; it
restarts once to show the new layout. Time control shows its time windows
and the digit set for each window. **Refresh** reads all values at once.

## Reading values

All values listed in `readValues` and `writeValues` are published together
in the QuickApp variable `values`, as JSON:

```json
{"pvPower":3120,"homePower":540,"batterySoc":64,"yieldDay":12.4,"batteryMinSoc":5}
```

Scenes and other QuickApps read it through the QuickApp's device ID:

```lua
local PLENTICORE = 123   -- device ID of this QuickApp

local function plenticore()
  for _, variable in ipairs(fibaro.getValue(PLENTICORE, "quickAppVariables") or {}) do
    if variable.name == "values" then
      local ok, values = pcall(json.decode, variable.value)
      if ok and type(values) == "table" then return values end
    end
  end
  return {}
end

local soc = plenticore().batterySoc
if soc and soc < 20 then fibaro.debug("scene", "Battery low: " .. soc .. " %") end
```

Outside the HC3, the same data is available from the HC3 REST API:
`GET /api/devices/123`, property `quickAppVariables`.

Numbers and on/off settings (`0`/`1`) are JSON numbers; states, names and time
control are text. To keep the controller's database quiet, the variable is
only written when a value changes by more than a small amount (10 W,
0.01 kWh, 1 %) or changes to or from zero; set `deadband = false` in the [options](#step-3-options-optional)
to write it on every change.

## Writing values

Settings listed in `writeValues` can be changed in three ways:

- with their switch or slider in the QuickApp's user interface;
- from scenes and other QuickApps with the `set` action:

  ```lua
  fibaro.call(123, "set", "batteryMinSoc", 30)
  ```

- from outside the HC3: `POST /api/devices/123/action/set` with the body
  `{"args": ["batteryMinSoc", 30]}`.

Every value is checked against the range the inverter reports before it is
written, and read back afterwards. A rejected value is logged, and the table
returns to the inverter's value.

Settings are read from the inverter every 5 minutes and after every change.
A setting changed on the inverter (web interface, app) is taken over and
logged.

## Scene example

A complete Lua scene that reads the current PV power and today's yield, and
sets the minimum battery state of charge to 10 %. Replace `123` with the
device ID of the QuickApp (shown in its **General** tab). `pvPower` and
`yieldDay` must be listed in `readValues`, `batteryMinSoc` in `writeValues` -
all three are in the defaults.

```lua
local PLENTICORE = 123   -- device ID of the KOSTAL PLENTICORE QuickApp

-- All values of the QuickApp as a table, e.g. values.pvPower.
local function plenticoreValues()
  for _, variable in ipairs(fibaro.getValue(PLENTICORE, "quickAppVariables") or {}) do
    if variable.name == "values" then
      local ok, values = pcall(json.decode, variable.value)
      if ok and type(values) == "table" then return values end
    end
  end
  return {}
end

-- Read: current PV power in W and today's PV yield in kWh.
local values = plenticoreValues()
fibaro.debug("scene", "PV power: " .. tostring(values.pvPower) .. " W, "
  .. "yield today: " .. tostring(values.yieldDay) .. " kWh")

-- Write: minimum battery state of charge to 10 %.
fibaro.call(PLENTICORE, "set", "batteryMinSoc", 10)
```

The scene log shows, for example, `PV power: 1597 W, yield today: 6.12 kWh`,
and the QuickApp's log `Setting 'batteryMinSoc' changed to 10 on the inverter`.
A value is `nil` if its name is not listed in `readValues` or `writeValues`, or
before the first reading after a restart.

Note: `batterySoc` is the battery's actual state of charge and can only be
read; the setting that can be changed is the minimum, `batteryMinSoc`.

## Child devices

Values in `childValues` get their own device: power values (W) as power meter,
energy values (kWh) as energy meter for the HC3 energy panel, percentages as
multilevel sensor.

- A child is created once. Its device ID stays the same across restarts and
  updates; names, rooms and icons you change are kept.
- Adding a name to `childValues` creates its child; removing a name deletes
  its child. Nothing else is created or deleted.
- A child deleted by hand is not recreated while the QuickApp runs. At the
  next start it is recreated with a new ID if its name is still in
  `childValues` - a reminder to remove it from the list.
- Child devices not created by this QuickApp are never touched.

## Value reference

The values offered depend on the inverter model; values it does not provide
stay empty.

### Measured values

Read only: list them in `readValues`. Those marked "Child: yes" can also be
listed in `childValues`.

| Name | Meaning | Unit | Child |
|---|---|---|---|
| `pvPower` | PV power, sum of all strings | W | yes |
| `pv1Power` | PV power of string 1 | W | yes |
| `pv2Power` | PV power of string 2 | W | yes |
| `pv3Power` | PV power of string 3 (inverters with three strings) | W | yes |
| `acPower` | AC output power of the inverter | W | yes |
| `homePower` | Home consumption | W | yes |
| `homeFromPv` | Home consumption covered by PV | W | yes |
| `homeFromBattery` | Home consumption covered by the battery | W | yes |
| `homeFromGrid` | Home consumption covered by the grid | W | yes |
| `gridPower` | Grid power at the energy meter: positive = import, negative = export | W | yes |
| `batteryPower` | Battery power: positive = discharging, negative = charging | W | yes |
| `batterySoc` | Battery state of charge | % | yes |
| `batteryCycles` | Battery charge cycles |  |  |
| `inverterState` | Inverter state: Off, Init, IsoMeas, GridCheck, StartUp, FeedIn, Throttled, ExtSwitchOff, Update, Standby, GridSync, GridPreCheck, GridSwitchOff, Overheating, Shutdown, ImproperDcVoltage, ESB, Unknown |  |  |
| `energyManagerState` | Energy manager state: Idle, EmergencyBatteryCharge, WinterModeStep1, WinterModeStep2 |  |  |
| `yieldDay` | PV yield today | kWh | yes |
| `yieldTotal` | PV yield since commissioning | kWh | yes |
| `homeDay` | Home consumption today | kWh | yes |
| `homeTotal` | Home consumption since commissioning | kWh | yes |
| `homeFromGridDay` | Home consumption from the grid today | kWh | yes |
| `homeFromGridTotal` | Home consumption from the grid since commissioning | kWh | yes |
| `homeFromPvDay` | Home consumption from PV today | kWh | yes |
| `homeFromPvTotal` | Home consumption from PV since commissioning | kWh | yes |
| `homeFromBatteryDay` | Home consumption from the battery today | kWh | yes |
| `homeFromBatteryTotal` | Home consumption from the battery since commissioning | kWh | yes |
| `batteryChargePvDay` | Energy charged into the battery from PV today | kWh | yes |
| `batteryChargePvTotal` | Energy charged into the battery from PV since commissioning | kWh | yes |
| `batteryChargeGridDay` | Energy charged into the battery from the grid today | kWh | yes |
| `batteryChargeGridTotal` | Energy charged into the battery from the grid since commissioning | kWh | yes |
| `batteryDischargeDay` | Energy discharged from the battery today | kWh | yes |
| `batteryDischargeTotal` | Energy discharged from the battery since commissioning | kWh | yes |
| `autarkyDay` | Autarky today | % | yes |
| `selfConsumptionDay` | Self-consumption rate today | % | yes |

### Settings

List a setting in `readValues` to read it, or in `writeValues` to read and change it.

| Name | Meaning | Unit | UI control |
|---|---|---|---|
| `batteryMinSoc` | Minimum state of charge of the battery (5-100) | % | slider 5-100 |
| `batteryMinHomeConsumption` | Home consumption from which the battery is used (at least 50) | W |  |
| `batterySmartControl` | Smart battery control: 0 = off, 1 = on |  | switch |
| `batteryDynamicSoc` | Dynamic minimum state of charge: 0 = off, 1 = on |  | switch |
| `batteryStrategy` | Battery usage strategy: 1 = automatic, 2 = automatic economical |  |  |
| `batteryTimeControl` | Time-controlled battery usage: 0 = off, 1 = on |  | switch |
| `batteryTimeControlMon` | Time control for Monday: 96 digits, one per quarter hour from 00:00 (see below) |  |  |
| `batteryTimeControlTue` | Time control for Tuesday: 96 digits, one per quarter hour from 00:00 (see below) |  |  |
| `batteryTimeControlWed` | Time control for Wednesday: 96 digits, one per quarter hour from 00:00 (see below) |  |  |
| `batteryTimeControlThu` | Time control for Thursday: 96 digits, one per quarter hour from 00:00 (see below) |  |  |
| `batteryTimeControlFri` | Time control for Friday: 96 digits, one per quarter hour from 00:00 (see below) |  |  |
| `batteryTimeControlSat` | Time control for Saturday: 96 digits, one per quarter hour from 00:00 (see below) |  |  |
| `batteryTimeControlSun` | Time control for Sunday: 96 digits, one per quarter hour from 00:00 (see below) |  |  |
| `activePowerLimitation` | Limit of the AC output power | W |  |
| `shadowManagement` | Shade management, one bit per string: 1 = string 1, 2 = string 2, 4 = string 3 |  |  |

### Device information

Read only: list them in `readValues`.

| Name | Meaning |
|---|---|
| `model` | Inverter model, e.g. PLENTICORE plus 8.5 |
| `firmwareVersion` | Firmware version of the main controller |
| `batteryType` | Connected battery type |
| `batteryExternalControl` | Battery control mode: internal, digitalIO or modbus (changed by the installer only) |

### Time control

`batteryTimeControl` switches time-controlled battery usage on or off.
`batteryTimeControlMon` … `batteryTimeControlSun` hold 96 digits per weekday,
one per quarter hour starting at 00:00:

| Digit | Meaning |
|---|---|
| `0` | no restriction |
| `2` | battery discharging blocked, charging from surplus allowed |
| `1` | used by the web interface for its other blocking option (not verified) |

KOSTAL does not document the digits; `2` was verified on a PLENTICORE plus G1.
When in doubt, set the time windows once in the inverter's web interface and
read the resulting value before writing your own.
The value table shows each window with its digit, e.g. `11:45-12:00 (2)`.

## Languages

The user interface is available in English, German, French and Italian and
follows the controller's language. French and Italian are not reviewed by a
native speaker - [corrections are welcome](https://github.com/schopf16/fibaro-qa-plenticore/issues/new?template=translation.yml).

## Privacy and security

This QuickApp communicates only with the inverter in your local network. It
does not contact the internet, does not check for updates and sends no
telemetry. The password is stored in a password-type variable, never written
to the log, and never sent to the inverter, not even encrypted: the login
proves knowledge of the password (SCRAM-SHA256).

- **Connection:** HTTPS by default (option `https`). The inverter's
  certificate is self-signed and is therefore accepted without verification:
  the traffic cannot be read, but a device that impersonates the inverter is
  not recognised by its certificate. The login detects it instead - it checks
  the inverter's signature and refuses a challenge with fewer than 10000 key
  derivation rounds, so no proof that would allow a fast password search is
  ever sent.
- **Random numbers:** the controller has no cryptographic random source.
  Nonces and keys come from a SHA-256 pool, seeded at every start and mixed
  with the inverter's own random values.
- **Plain HTTP** (`https = false`) is only needed for inverters without
  HTTPS. The session ID can then be read by anyone who can see the traffic
  in your network.

Do not make the inverter's web interface or Modbus port reachable from the
internet.

## Troubleshooting

All log lines of this QuickApp carry the tag **`PLENTICORE`** - filter the HC3
console by it. If the QuickApp is installed more than once, each instance
appends its device ID, e.g. `PLENTICORE_123`.

1. Set `logLevel = "debug"` in the [options](#step-3-options-optional) and save
   (this restarts the QuickApp).
2. Reproduce the problem.
3. Copy the log from the line `KOSTAL PLENTICORE v... starting ...` to the problem.
4. Also look for `QUICKAPP<id>` lines with "QuickApp crashed" - they should
   never appear; if they do, please include them.
5. Before sharing, remove addresses and personal names, then open an
   [issue](https://github.com/schopf16/fibaro-qa-plenticore/issues/new?template=bug_report.yml).

"not reachable" right after switching to a new inverter: if the inverter
does not offer HTTPS, set `https = false` in the [options](#step-3-options-optional).

"Login rejected" means the inverter refused the password. The QuickApp then
stops polling until the variables are saved again, so that repeated attempts
cannot lock the account.

## Support

- Questions and bugs: [GitHub issues](https://github.com/schopf16/fibaro-qa-plenticore/issues)
- Security issues: please report privately via
  [security advisories](https://github.com/schopf16/fibaro-qa-plenticore/security/advisories/new)

## License

[MIT](LICENSE)

This is an independent project, not affiliated with or endorsed by KOSTAL
Solar Electric GmbH or FIBARO. KOSTAL, PLENTICORE and PIKO IQ are trademarks
of their respective owners and are used here only to name the supported devices.
