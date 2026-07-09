# Flashlock — iOS app layer

The app, DeviceActivity monitor, and shield extensions for Flashlock. The
platform-independent engine (FSRS scheduler, quiz generation/grading, gate
state machine) lives in `../FlashlockCore` and is consumed as a local Swift
package. Architecture and design decisions: `../docs/02-architecture.md`.

## Building (macOS required)

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen):

   ```sh
   brew install xcodegen
   ```

2. Generate the Xcode project from `project.yml`:

   ```sh
   cd flashlock/Flashlock
   xcodegen generate
   open Flashlock.xcodeproj
   ```

3. Set your signing team. Either uncomment `DEVELOPMENT_TEAM` in `project.yml`
   and regenerate, or select your team in Xcode's Signing & Capabilities tab
   for **all four targets** (Flashlock, FlashlockMonitor, FlashlockShieldUI,
   FlashlockShieldAction). With `CODE_SIGN_STYLE = Automatic`, Xcode will
   provision the Family Controls (development) capability and the
   `group.com.flashlock.shared` App Group automatically. If provisioning
   fails, register the App Group once in your developer account
   (Certificates, Identifiers & Profiles → Identifiers → App Groups).

4. Select the `Flashlock` scheme and a **physical device**, then build & run.

## Family Controls capability caveats

- **Development works immediately.** The development flavor of the
  `com.apple.developer.family-controls` entitlement needs no approval — build
  to your own device and everything (authorization prompt, shields, monitor
  callbacks) works.
- **TestFlight and App Store do NOT work until Apple approves the
  distribution entitlement — one request per bundle ID, 4 total:**
  `com.flashlock.app`, `com.flashlock.app.monitor`,
  `com.flashlock.app.shieldui`, `com.flashlock.app.shieldaction`. File them
  via Apple's Family Controls capability request form as early as possible;
  turnaround is days-to-weeks and silent. A TestFlight build with only the
  development entitlement uploads fine but Family Controls silently fails at
  runtime.
- After the grants arrive, make sure the entitlement is present in the
  **Release** configuration and regenerate provisioning profiles — a stale
  profile is the most common post-approval failure.
- App Review guideline 4.10: don't paywall the Screen Time capability itself;
  monetize features.

## Device-only testing notes

- **The Simulator does not work** for anything Screen Time related:
  `requestAuthorization` typically fails with FamilyControlsError code 3, the
  FamilyActivityPicker is blank, shields never render, and usage thresholds
  never fire. Test on hardware only.
- DeviceActivity schedules have an undocumented **15-minute minimum
  interval**, so wall-clock tests of the re-lock path take at least 15
  minutes. Short earned-time grants use a usage-threshold event instead
  (see `Shared/RelockScheduler.swift`) which you can exercise faster by
  actively using a shielded app.
- Monitor callbacks behave differently attached vs. detached from the Xcode
  debugger; verify schedule logic with the cable unplugged.
- The custom shield falling back to the system "Restricted" shield almost
  always means a target mismatch: check that every extension has the same
  iOS deployment target as the app (17.4), the Family Controls capability,
  and the App Group; then clean build, delete the app, and if needed restart
  the device.
- If callbacks stop firing entirely, revoking and re-granting Screen Time
  permission in Settings is the community-standard reset.

## Layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen spec: 4 targets, entitlements, local FlashlockCore package |
| `App/` | SwiftUI app: onboarding, home, study, gate session, deck CRUD, settings |
| `Shared/` | App Group store, idempotent shield reconciler, DeviceActivity schedulers — compiled into multiple targets |
| `Monitor/` | DeviceActivityMonitor extension (headless, ~6 MB memory ceiling) |
| `ShieldUI/` | ShieldConfigurationDataSource extension (custom shield appearance) |
| `ShieldAction/` | ShieldActionDelegate extension (shield buttons → gate flow) |
