# Agent Instructions for PowerAdjuster

This file provides context, commands, and conventions for AI agents operating within the PowerAdjuster Garmin Connect IQ repository.

## 1. Project Overview
PowerAdjuster is a Connect IQ Data Field application written in Monkey C (`*.mc`). It is designed for cycling and running power meters. Its primary purpose is to mathematically adjust real-time power metrics based on altitude, unacclimatized hypoxia, and physiological variables like VO2Max (EIAH), and display this against customizable power zones.

## 2. Build & Test Commands

**Prerequisites:** 
You must use the Garmin Connect IQ SDK (`monkeyc`, `monkeydo`, `connectiq`, `monkeybrains.jar`). Because this environment often runs on macOS/Linux with complex SDK paths, building via the raw `.jar` is sometimes required if `monkeyc` is not in the system PATH.

### Build (Standard via `monkeybrains.jar`)
The most reliable way to compile in this environment (assuming the SDK path is known and the developer key exists):
```bash
java -Xms1g -Dfile.encoding=UTF-8 -Dapple.awt.UIElement=true \
  -jar "/Users/oleksiy/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b/bin/monkeybrains.jar" \
  -o bin/PowerAdjuster.prg \
  -f monkey.jungle \
  -y /Users/oleksiy/eclipse-workspace/drive-download-20220612T074040Z-001/developer_key.der \
  -d edge1040_sim -w
```
*(Note: If `monkeyc` is available in PATH, you can use `monkeyc -y <key.der> -f monkey.jungle -d <device> -o bin/PowerAdjuster.prg`)*

### Run Simulator
1. Start the simulator background process:
   ```bash
   connectiq
   ```
2. Push the compiled `.prg` to the simulator (e.g., for an Edge 1040):
   ```bash
   monkeydo bin/PowerAdjuster.prg edge1040
   ```

### Testing
There is currently no formal unit testing framework (like `Toybox.Test`) established in this repository. Agents should rely on manual visual verification via the simulator or verify logic via isolated math scripts (Node/Python) before implementing complex algorithms in Monkey C.

## 3. Code Style & Architecture Guidelines

### Language: Monkey C
Connect IQ uses **Monkey C**, an object-oriented language similar to Java, C#, and JavaScript. It is strongly typed but allows duck-typing. It runs on highly constrained wearable devices, so **efficiency is critical.**

### Memory & Performance Constraints
- **Watch memory is extremely limited (often 16KB - 32KB for a Data Field).**
- Minimize object creation inside the `compute(info)` and `onUpdate(dc)` loops. 
- Do not instantiate new arrays or complex objects on every tick (1Hz). Initialize them in `initialize()` or `onSettingsChanged()` and reuse them.
- Avoid deep recursion and excessive function calls in the main compute loop.
- Use simple mathematical operations where possible (e.g., polynomial approximations instead of complex `Toybox.Math.pow()` calls if it saves CPU).

### Imports & Naming Conventions
- Always alias Toybox modules at the top of the file:
  ```monkeyc
  using Toybox.WatchUi as Ui;
  using Toybox.System as Sys;
  using Toybox.Math as Math;
  using Toybox.Graphics as Gfx;
  using Toybox.UserProfile as UserProfile;
  ```
- **Classes:** PascalCase (e.g., `class PowerAdjuster`, `class PowerDataField`).
- **Constants:** UPPER_SNAKE_CASE (e.g., `const UNACCLIMATIZED_FACTOR = 0.063d;`).
- **Variables/Methods:** camelCase or snake_case is accepted, but try to match the surrounding code. In this repo, snake_case is heavily used for math variables (`sea_level_watts`, `unacclimatized_reduction`) and camelCase for methods (`getAcclimatizedReductionFactor`).
- **Global Settings:** When pulling properties from `Application.getApp().getProperty()`, store them in class variables (e.g., `var ALTPOWER;`) rather than `const` so they can be mutated via `onSettingsChanged()`.

### Handling Settings & Properties
- All user-configurable settings are defined in `resources/properties.xml` and mapped in `bin/PowerAdjuster-settings.json`.
- Settings updates occur mid-activity. If you add a new setting, you MUST:
  1. Add it to `<properties>`, `<strings>`, and `<settings>` in `properties.xml`.
  2. Declare a `var` for it in `PowerDataField`.
  3. Load its value inside the `onSettingsChanged()` method so the app responds immediately to changes from the Garmin Connect app.

### Error Handling & Null Checks
- **Never trust `info` variables.** Sensors frequently drop out. You must check for nulls before doing math:
  ```monkeyc
  if (info.currentPower != null) { ... }
  if (info.altitude != null) { ... }
  ```
- Defensive bounds-checking is vital. If a user sets a property to a nonsensical value (e.g., altitude to 900,000m), clamp it using basic conditional logic (`if (reduction < 0.1) { reduction = 0.1; }`) to prevent Divide-By-Zero errors or negative power values.

### Permissions
- Accessing restricted data (e.g., Sensors, UserProfile for VO2Max, FitContributor) requires explicit permission in `manifest.xml`.
- If an agent adds a call to a new module (like `Toybox.UserProfile` or `Toybox.Position`), they must add `<iq:uses-permission id="ModuleName"/>` to the `manifest.xml`.

### Drawing / UI (onUpdate)
- The Data Field UI is drawn in `onUpdate(dc)` using the `Graphics.Dc` context.
- Keep drawing logic fast. Calculate values in `compute()` and store them in variables, then read those variables in `onUpdate()`. 
- Only clear the screen and redraw if necessary.
- Respect the user's background/foreground colors (`getBackgroundColor()`).
