# LingoPod

A podcast player for language learners: on-device transcription,
lyrics-style synced transcript overlay, tap-to-translate, and
highlight-to-explain — all offline-capable, no accounts, no servers.

See `docs/00-product-overview.md` and `docs/01-architecture.md` for the
product and technical contract. Module specs live in `docs/specs/`.

## Prerequisites

- A Mac running **Xcode 26** or later (iOS 26 SDK; Swift 6).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), installed via
  Homebrew:

  ```sh
  brew install xcodegen
  ```

- No other third-party tooling or dependencies are required — this project
  intentionally has zero third-party Swift packages (see
  `docs/01-architecture.md` §1).

## Building and running the app

This repository does **not** commit an `.xcodeproj` — it's generated from
`project.yml`. Every time you pull changes that touch `project.yml`, or
before your first build, regenerate the project:

```sh
cd lingopod
xcodegen generate
```

This produces `LingoPod.xcodeproj`. Open it:

```sh
open LingoPod.xcodeproj
```

Select the `LingoPod` scheme and an iOS 26+ simulator (or a device), then
Run (⌘R). On first launch you should land on an empty Library tab with a
Search tab alongside it.

`LingoPod.xcodeproj` and the `Generated/` directory (which holds the
XcodeGen-produced Info.plist and entitlements) are build artifacts and are
git-ignored — see `.gitignore`. Never hand-edit generated files; edit
`project.yml` and re-run `xcodegen generate`.

## Running app-target tests

With the project open in Xcode: ⌘U on the `LingoPod` scheme runs both the
app's `LingoPodTests` and (if your XcodeGen version wires it up — see
`docs/specs/M0-scaffolding.md` §2) `LingoPodKitTests`.

## Running LingoPodKit tests (no Xcode project needed)

`LingoPodKit` is a self-contained SwiftPM package with no UIKit/SwiftUI
imports, so its tests run without generating or opening the Xcode project,
and without booting a simulator:

```sh
cd lingopod/LingoPodKit
swift test
```

This is the fastest inner loop for logic covered by `LingoPodKit`
(feed/transcript parsing, segmentation, cache-key math, etc. — see
`docs/01-architecture.md` §9) and is also runnable in CI or any Linux/Mac
box with a Swift 6 toolchain, independent of Xcode.

## Repository layout

See `docs/01-architecture.md` §2 for the full annotated tree.

`LingoPodKit/Sources/LingoPodKit/Models/` (SwiftData `@Model` types plus
their supporting enums) is implemented by M0 itself per architecture
§11.1 — this is a deliberate deviation from the M0 spec's original text,
which assumed M1 would own the model definitions. See
`docs/01-architecture.md` §11.1 for the reconciliation decision.
