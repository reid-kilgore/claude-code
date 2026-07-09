> Research brief produced by a web-research agent on 2026-07-09 for the Flashlock project.
> Topic: FamilyControls entitlement & authorization. Claims are cited inline; confidence flags are the agent's own.

# Research findings: `com.apple.developer.family-controls` entitlement & FamilyControls AuthorizationCenter (as of mid-2026)

## 1. Entitlement: development vs. distribution

- **Claim:** The `com.apple.developer.family-controls` entitlement can be used freely for development by adding the "Family Controls" capability in Xcode (Signing & Capabilities); Xcode manages it automatically with automatic signing. No Apple approval is needed for development builds.
  - Sources: [Requesting the Family Controls entitlement (Apple docs)](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement) (fetched via docs JSON endpoint), [Apple Developer Forums thread 712870](https://developer.apple.com/forums/thread/712870) (DTS engineer confirmation).
  - Confidence: Apple official doc — high.

- **Claim:** For distribution (App Store or TestFlight), the Account Holder must request the entitlement from Apple. The exact request URL is **https://developer.apple.com/contact/request/family-controls-distribution** (must be logged into the developer account). An alternative path now exists: the "Capability Requests" tab in Certificates, Identifiers & Profiles, selecting "Family Controls" from the Capabilities list.
  - Sources: [Apple doc: Requesting the Family Controls entitlement](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement), [Forum thread 735888 "Family Controls Request Form"](https://developer.apple.com/forums/thread/735888).
  - Confidence: Apple official doc + multiple forum confirmations — high. The "Capability Requests tab" alternative is newer; version of the portal UI may vary.

- **Claim:** The grant is **per app / per bundle ID, not per account**: Apple's doc says to submit one request per app, and if the app includes Screen Time extensions (Device Activity Monitor, Device Activity Report, Shield Action, Shield Configuration), a **separate request must be submitted for each extension's bundle ID** under the same Apple ID.
  - Sources: [Apple doc](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement), [thread 712870](https://developer.apple.com/forums/thread/712870), [thread 813073](https://developer.apple.com/forums/thread/813073).
  - Confidence: Apple official doc + multiple forum reports — high. (Note: once granted it appears as a "managed capability" with status "Assigned" in the account, but enablement is per App ID.)

- **Claim:** The form asks for: the container app's bundle ID (not extension bundle IDs on the main request), a description of the app and how it will use the entitlement / business need; the form gives **no submission confirmation and no status tracking**.
  - Sources: [thread 735888](https://developer.apple.com/forums/thread/735888), [Itsuki Medium post "Take Family Control To Production/Distribution"](https://medium.com/@itsuki.enjoy/swift-ios-take-family-control-to-production-distribution-83da9b3346c6) (403 on direct fetch; content via search excerpts).
  - Confidence: multiple forum reports + blog — medium-high; exact form fields may change over time.

- **Claim:** Approval timelines are highly variable: reports range from ~1–2 days to 31–33 days, ~3 weeks typical, 4.5 weeks reported, and extension requests sometimes stuck 2+ weeks after the main app was approved in 2 days (reports through late 2025).
  - Sources: [thread 725036 "3+ weeks of waiting"](https://developer.apple.com/forums/thread/725036), [thread 809190](https://developer.apple.com/forums/thread/809190), [thread 809208](https://developer.apple.com/forums/thread/809208), [thread 812332](https://developer.apple.com/forums/thread/812332).
  - Confidence: multiple independent forum reports — high that variance is real; no official SLA exists.

- **Claim:** After approval, the entitlement must be enabled per App ID under **Certificates, Identifiers & Profiles > Identifiers > (your App ID) > Additional Capabilities > Family Controls** (the tab appears only after granting), for the app **and every extension** that uses it; then distribution provisioning profiles must be regenerated, and `com.apple.developer.family-controls` should appear in the profile's entitlement allowlist (verifiable per TN3125). If the Xcode project already had the capability with automatic signing, Xcode updates distribution signing automatically after approval.
  - Sources: [Apple doc](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement), [thread 712870 (DTS: dump profile per TN3125)](https://developer.apple.com/forums/thread/712870), [thread 701874](https://developer.apple.com/forums/thread/701874), [eas-cli issue 2715](https://github.com/expo/eas-cli/issues/2715).
  - Confidence: Apple doc + DTS forum answer + multiple reports — high.

## 2. `requestAuthorization(for:)` — `.individual` vs `.child`

- **Claim:** `requestAuthorization(for:)` and the `FamilyControlsMember` enum (`.individual`, `.child`) were introduced in **iOS 16.0 / iPadOS 16.0**. The original iOS 15 API was `requestAuthorization(completionHandler:)`, which supported only the **child/parental-control model** and is now deprecated. `AuthorizationCenter` itself is iOS 15.0+.
  - Sources: [requestAuthorization(for:) doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter/requestauthorization(for:)), [FamilyControlsMember doc](https://developer.apple.com/documentation/familycontrols/familycontrolsmember), [AuthorizationCenter doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter) (all fetched via Apple's docs JSON).
  - Confidence: Apple official doc — high.

- **Claim:** `.individual` **works on a standalone adult device without Family Sharing** — WWDC22 "What's new in Screen Time API" states iOS 16 "authorizes independent users from their own device," any number of apps per device can hold individual authorization, and the implicit parental-control restrictions on **iCloud sign-out and app deletion do not apply** to individually-authorized apps (i.e., the user can always delete the app or sign out of iCloud).
  - Sources: [WWDC22 session 110336](https://developer.apple.com/videos/play/wwdc2022/110336/), [Apple requestAuthorization(for:) doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter/requestauthorization(for:)) ("the system removes restrictions that would prevent the user from bypassing parental controls, allowing them to delete the app or sign out of iCloud").
  - Confidence: Apple official (WWDC + docs) — high.

- **Claim:** User experience for `.individual`: on first request the system shows an **alert followed by an authentication sheet using Face ID / Touch ID** (device owner authenticates themselves); subsequent calls do not re-prompt — they only set/refresh `authorizationStatus`.
  - Sources: [AuthorizationCenter doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter), [requestAuthorization(for:) doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter/requestauthorization(for:)).
  - Confidence: Apple official doc — high. (Docs name Face ID/Touch ID; passcode fallback is standard LocalAuthentication behavior but not explicitly documented here — minor uncertainty.)

- **Claim:** `.child` must be requested **on the child's device**, signed into a child iCloud account that is part of a Family Sharing group; the system displays an authentication sheet where a **parent/guardian enters their credentials** to approve or deny. Running it on a non-child / non-Family-Sharing account fails with `FamilyControlsError.invalidAccountType` (error code 2, "device isn't signed into a valid iCloud account" / not a valid child account).
  - Sources: [FamilyControlsError.invalidAccountType doc](https://developer.apple.com/documentation/familycontrols/familycontrolserror/invalidaccounttype), [forum thread 685861](https://developer.apple.com/forums/thread/685861), [forum thread 682257](https://developer.apple.com/forums/thread/682257), [WWDC21 session 10123](https://developer.apple.com/videos/play/wwdc2021/10123/).
  - Confidence: Apple doc + multiple forum reports — high.

- **Claim:** FamilyControls authorization is unreliable/broken in the **Simulator** (commonly `FamilyControlsError error 3` / `invalidArgument` for `.individual`); a physical device is effectively required, despite an Apple engineer asserting Simulator support.
  - Sources: [forum thread 708050](https://developer.apple.com/forums/thread/708050), [forum thread 684355](https://developer.apple.com/forums/thread/684355).
  - Confidence: multiple forum reports; contradicts one Apple staff statement — medium; may vary by Xcode/OS version.

- **Claim:** Authorization always fails in compatible iPad/iPhone apps running on **visionOS**.
  - Source: [AuthorizationCenter doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter).
  - Confidence: Apple official doc — high.

## 3. Revocation and status observation

- **Claim:** After an app is authorized, iOS adds **two user-facing switches**: one in **Settings > Screen Time > "Apps with Screen Time Access"** and one in the app's own per-app Settings page ("Screen Time Restrictions"); either can revoke authorization. For `.individual`, the user can also simply delete the app (no restriction). For `.child` (parental-control) authorization, revocation/deletion is gated by parental approval; as of iOS 26.4 a parent deleting a Screen-Time-authorized app from a child device is prompted for the parent's Apple Account credentials.
  - Sources: [WWDC22 session 110336](https://developer.apple.com/videos/play/wwdc2022/110336/), [Tech Lockdown article on iOS 26 Screen Time changes](https://www.techlockdown.com/articles/ios-26-screen-time-changes).
  - Confidence: WWDC official for the two switches — high; iOS 26.4 deletion-flow detail from a single reputable blog — medium, version-dependent.

- **Claim:** When authorization is revoked (by user toggle, parent, or the app calling `revokeAuthorization(completionHandler:)`), the app's Screen Time privileges end and **tokens in existing `FamilyActivitySelection`s are voided**, which disables associated shields/monitoring; apps should observe status changes rather than assume permanence. The Screen Time toggle is NOT protected by the Screen Time passcode, so restrictions built on FamilyControls (individual mode) can be trivially self-revoked — a known weakness for blocker apps.
  - Sources: [WWDC22 session 110336](https://developer.apple.com/videos/play/wwdc2022/110336/) (tokens voided on revocation), [AuthorizationCenter.revokeAuthorization doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter), [riedel.wtf "State of the Screen Time API 2024"](https://riedel.wtf/state-of-the-screen-time-api-2024/) (easy-revocation complaint; page 403'd on direct fetch, content via search excerpt).
  - Confidence: token-voiding = Apple official (WWDC); the exact runtime teardown sequence of active `ManagedSettingsStore` shields on revocation is less precisely documented — medium; flag as partially inferred.

- **Claim:** `AuthorizationStatus` cases are `notDetermined`, `denied`, `approved` (iOS 15.0+), plus a new **`approvedWithDataAccess`** case added in **iOS 26.4** (EU-only, DMA-related): grants non-tokenized data (real bundle IDs, web domains) via `FamilyActivityData`, requires the additional `com.apple.developer.family-controls.app-and-website-usage` capability, only one app per device may hold it, and outside the EU it is never returned. Status changes can be observed via the published property (`$authorizationStatus`, a `Published<AuthorizationStatus>.Publisher` on `AuthorizationCenter.shared`) — note the property-wrapper projection is the documented "authorizationStatusPublisher" mechanism.
  - Sources: [AuthorizationStatus doc](https://developer.apple.com/documentation/familycontrols/authorizationstatus), [approvedWithDataAccess doc](https://developer.apple.com/documentation/familycontrols/authorizationstatus/approvedwithdataaccess), [AuthorizationCenter doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter).
  - Confidence: Apple official docs — high. The iOS 26.4/EU case is very version- and region-dependent; flag prominently if targeting mid-2026.

- **Claim:** Authorization status can change externally without app involvement (e.g., a child account graduating to adult, a parent changing settings), so apps must handle status transitions at any time.
  - Source: [AuthorizationCenter doc](https://developer.apple.com/documentation/familycontrols/authorizationcenter).
  - Confidence: Apple official doc — high.

## 4. App Store review implications

- **Claim:** Current guidelines prohibit **monetizing Screen Time APIs** as such: "You may not monetize built-in capabilities provided by the hardware or operating system … or Apple services and technologies, such as … Screen Time APIs" — appearing under **Guideline 4.10 (Monetizing Built-In Capabilities)** in the current (2025-renumbered) guidelines. You can charge for your app/features, but not for raw access to the API capability itself.
  - Source: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) (fetched; 4.10 quoted verbatim).
  - Confidence: Apple official, verified by direct fetch — high. Note: guideline **numbering is version-dependent**; this clause has lived under different numbers historically.

- **Claim:** **Guideline 5.5 (Mobile Device Management)** is the parental-controls-adjacent rule: MDM may only be offered by enterprises/education/government and "in limited cases, companies utilizing MDM for parental controls"; such apps "may not sell, use, or disclose to third parties any data for any purpose, and must commit to this in their privacy policy." This is the origin of the no-third-party-analytics/ads posture for parental-control data (introduced June 2019 after the Screen Time app purge). Important nuance: 5.5 textually targets **MDM**, not the FamilyControls framework per se — FamilyControls-only apps are governed mainly by 4.10, 5.1.x privacy rules, and the entitlement-request vetting itself.
  - Sources: [Apple news: Updates to the App Store Review Guidelines (June 3, 2019)](https://developer.apple.com/news/?id=06032019j), [AppleInsider coverage](https://appleinsider.com/articles/19/06/04/apple-eases-up-on-third-party-parental-control-app-restrictions-introduces-new-mdm-guidelines), [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
  - Confidence: Apple official for 5.5 text; the mapping "5.5 applies to FamilyControls apps" is **commonly assumed but not literal** — flag as uncertain/interpretive.

- **Claim:** The design-time data protection for FamilyControls is architectural rather than purely policy: the standard API returns only **opaque tokens** (no bundle IDs/URLs), so a third-party app cannot exfiltrate what the user used, which Apple cites as the privacy model ("app knows Safari ran 10 min, not what you did"). The iOS 26.4 EU `approvedWithDataAccess` path relaxes this and adds the separate `app-and-website-usage` capability gate.
  - Sources: [WWDC21 session 10123](https://developer.apple.com/videos/play/wwdc2021/10123/), [approvedWithDataAccess doc](https://developer.apple.com/documentation/familycontrols/authorizationstatus/approvedwithdataaccess).
  - Confidence: Apple official — high.

- **Claim:** The distribution-entitlement form itself acts as a use-case review: Apple asks how the app will use the entitlement, and the form was **broadened for iOS 16** to allow non-parental-control uses (habit/focus/blocker apps), per DTS. Community reports of "rejections" cluster around (a) entitlement requests silently denied/ignored, (b) App Store Connect build validation errors for new extension points (e.g., `com.apple.ManagedSettings.ShieldConfigurationExtensionPoint`, 409 errors), and (c) missing Additional Capabilities configuration — rather than published guideline-based content rejections.
  - Sources: [thread 712870 (DTS on updated form)](https://developer.apple.com/forums/thread/712870), [thread 735888](https://developer.apple.com/forums/thread/735888), [Family Controls forum tag](https://developer.apple.com/forums/tags/family-controls).
  - Confidence: DTS statement + multiple forum reports — medium-high; individual rejection anecdotes are single-report grade.

- **Claim:** A privacy policy is mandatory for all apps (guideline 5.1.1), and for parental-control/MDM-classified apps it must include the explicit no-sell/no-disclose commitment (5.5). Broad guideline 5.1.2 restrictions on repurposing sensitive data for advertising also apply; a Nov 2025 update (guideline 5.1.2(i)) further requires disclosure/consent before sharing personal data with third-party AI.
  - Sources: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [TechCrunch on Nov 2025 update](https://techcrunch.com/2025/11/13/apples-new-app-review-guidelines-clamp-down-on-apps-sharing-personal-data-with-third-party-ai/).
  - Confidence: Apple official + reputable press — high; the AI clause is tangential context.

- **Claim:** I found **no Apple-published document titled "Screen Time API usage terms"** that bans combining FamilyControls with third-party analytics/ads outright; the enforceable instruments are guideline 5.5 (for MDM/parental-control data), 5.1.x, 4.10, and the entitlement vetting. Any stronger claim (e.g., "Screen Time apps may not include third-party ads SDKs at all") is **not verified**.
  - Confidence: negative finding after multiple searches — medium; a non-public condition could exist in the grant email Apple sends, which I could not verify.

## 5. TestFlight

- **Claim:** **TestFlight requires the distribution entitlement** — the development-mode Family Controls capability is insufficient because TestFlight builds are signed with a distribution provisioning profile like App Store builds. Confirmed by Apple DTS (Quinn "The Eskimo!"): "You can use this entitlement for development but, for distribution [including TestFlight], you'll need to apply for access to it." Uploads without the granted entitlement fail with provisioning/entitlement errors (portal shows Family Controls "available only for Development").
  - Sources: [thread 712870](https://developer.apple.com/forums/thread/712870) (DTS answer), [thread 806285 "Family Controls entitlement not working on TestFlight"](https://developer.apple.com/forums/thread/806285), [thread 721914](https://developer.apple.com/forums/thread/721914).
  - Confidence: Apple DTS + multiple forum reports — high.

- **Claim:** After the grant, developers should verify via the capability's info button that "Provisioning Support" lists the needed distribution methods (App Store, TestFlight, etc.) — the grant enumerates supported distribution channels.
  - Source: [Apple doc: Requesting the Family Controls entitlement](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement).
  - Confidence: Apple official doc — high.

**Key version-dependency flags:** `.individual`/`.child` split = iOS 16+ only (iOS 15 = child-only, deprecated API); `approvedWithDataAccess` + `app-and-website-usage` capability = iOS 26.4, EU-only; guideline numbering (4.10/5.5) reflects the current renumbered guidelines and has shifted historically; approval timelines and portal UI ("Capability Requests" tab) are point-in-time observations. Direct-fetch limitations: Apple doc pages were read via their `tutorials/data/...json` endpoints (reliable); riedel.wtf, wwdcnotes.com, and Medium blocked fetches (403), so those claims rest on search-index excerpts.
