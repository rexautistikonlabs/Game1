# FieldForge

A native iOS field app for nonprofit staff and volunteers doing outreach,
solicitation, events, and site visits.

The premise: someone is standing on a sidewalk, holding a clipboard in one hand
and a phone in the other, in front of a shop owner who has thirty seconds. In
that thirty seconds they should be able to capture who this is, take the money,
hand over a signed receipt or a proper IRS acknowledgment letter, record how it
went, and set a reminder — with zero bars of signal, and lose nothing.

Everything in this project is arranged around that thirty seconds.

---

## On the name

`FieldForge` is fine and it is what the code uses. Two alternatives worth
considering before the App Store listing goes up, because "Forge" reads slightly
industrial for a sector that talks in terms of relationships:

- **Doorstep** — plain, memorable, and it names the actual moment the app is for.
- **Fieldbook** — quieter, and it hints at the CRM half rather than only the
  transaction half.

Renaming later is a find-and-replace plus a bundle identifier change; the
product name appears in `project.yml`, `Info.plist`, and the module name.

---

## Building it

There is no `.xcodeproj` in the repository — a generated project file is a merge
conflict waiting to happen. Use [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd ios/FieldForge
xcodegen generate
open FieldForge.xcodeproj
```

Then set your Apple Developer Team ID in `project.yml` (`DEVELOPMENT_TEAM`) and
change `PRODUCT_BUNDLE_IDENTIFIER` from `org.example.fieldforge` to your own.

Prefer not to use XcodeGen? Create an iOS App target named `FieldForge`, drag
the `FieldForge/` folder in as a folder reference, point `INFOPLIST_FILE` and
`CODE_SIGN_ENTITLEMENTS` at the files in `FieldForge/App/`, and copy the build
settings out of `project.yml`.

**Requirements:** Xcode 15.3+, iOS 17.0+ deployment target, Swift 5 language
mode. No third-party dependencies — no CocoaPods, no SPM packages, nothing to
resolve.

> **This code has not been compiled.** It was written in a Linux environment
> with no Swift toolchain or Xcode available, so treat the first build as a
> normal first build: expect a handful of signature and inference fixes, not a
> rewrite. Everything is plain SwiftUI/SwiftData/PDFKit/PassKit against
> documented iOS 17 APIs, and the pieces most likely to need a nudge are called
> out under [Remaining work](#remaining-work).

### Before the first run

1. **Settings → Letterhead.** The app will not issue a document until the
   organization has a name, an address, an EIN, and a signatory. That is a
   deliberate refusal, not a validation quirk: a receipt with no organization
   name on it is worse than no receipt.
2. Optionally save a signature so you are not drawing one with a fingertip at
   every door.

There is no seeded demo data in the shipping path. A staffer's first launch shows
their own empty route, not sample donors they have to delete before trusting the
numbers. Every SwiftUI preview *does* get a seeded store — see
`SeedData.populate`.

---

## What it does

### 1. Dual document engine

One gift, two completely different pieces of paper, switched with one control
and no re-entry of anything:

| | Receipt | Acknowledgment letter |
|---|---|---|
| Shape | Business-style, one page, itemised | Formal block letter, serif, paginated |
| For | Handing across a counter | The donor's tax file in April |
| Total | Large, boxed, unmissable | Inside a summary block, prose around it |
| Tax language | One compact line | Full substantiation paragraph, set apart |

Both are real PDFs built with Core Text — selectable text an accountant can copy
an amount out of, correct physical page size on US Letter *and* A4, proper
pagination, and a signature block that never orphans across a page break.

Branding is free forever: logo, brand colour, letterhead lines, EIN, tagline,
signature. The paid tier adds the full-colour letterhead band, a custom footer,
and per-document signatory overrides.

**The IRS language is the part that has to be right**, so it lives alone in
`Documents/TaxLanguage.swift` — pure functions, no I/O, no models, and the most
heavily tested file in the project. It follows IRS Publication 1771:

- "No goods or services were provided in exchange for this contribution" on cash
  acknowledgments (required at $250 and above).
- Quid pro quo disclosure above $75, with the arithmetic shown and the
  deductible portion stated. Never negative.
- **In-kind gifts are described, never valued.** A charity putting its own
  valuation on a noncash acknowledgment is the classic mistake in this space, so
  the app refuses to by default. A donor-stated figure prints only if the
  organization opts in, and always labelled as the donor's own estimate.
- Form 8283 above $500, qualified appraisal above $5,000.
- A 501(c)(3) toggle. Switch it off and letters state plainly that contributions
  are *not* deductible — that protects the donor, which is the point.
- A pledge gets a pledge confirmation, never a tax acknowledgment.

Issued documents freeze a snapshot of everything printed on them
(`GeneratedDocument`), so a donor who moves or an organization that rebrands
cannot retroactively change a receipt from two years ago. Correcting one issues
a new document with an `-R1` suffix and marks the original superseded; both are
kept, so a donor holding the old copy can be told which is current.

### 2. Payments

`Payments/` is built around one rule: **an electronic payment either clears or
it does not exist.** A tax acknowledgment is never issued for money that has not
arrived (`Gift.isPaymentConfirmed` gates it, and there is a test for that).

- **Apple Pay** — full `PKPaymentAuthorizationController` implementation. The
  payment sheet shows its green tick only after the processor confirms, because
  a tick before the money moves is a lie the donor watches you tell. The payer's
  email is requested on the sheet, which is what makes "receipt sent before they
  walk away" possible.
- **Tap to Pay on iPhone** — the `ProximityReader` path is present and reports
  availability precisely (unsupported device / missing entitlement / not
  provisioned / offline), each with an explanation and a manual fallback. It is
  gated behind a compile flag until Apple grants the entitlement; see
  [Wiring Tap to Pay](#wiring-tap-to-pay).
- **Manual** — cash, cheque, in-kind, card-taken-elsewhere, pledge. Not a
  consolation prize: in real outreach this is most gifts, so it is a first-class
  `PaymentProvider` with the same interface, and when there is no signal these
  move to the *top* of the method list while the dead electronic buttons drop
  below with a plain explanation.

Amount, date, card description and payer name auto-populate from a cleared
payment, and the amount field locks — so what the donor was charged and what the
document says can never disagree.

### 3. The Warmth System

A four-point rating (plus a deliberately separated "do not contact again"),
tapped once at the end of every interaction. Twenty documented "not today"s are
how the twenty-first door opens.

- Contact-level warmth is a **recency-weighted roll-up** of every visit rating,
  with a one-year half-life, so a business that was cold in 2019 and warm last
  week reads as warm. `doNotReturn` is absorbing and overrides everything.
- Private notes (this device only) and shared notes (the team) are separate
  fields, everywhere, on every tier.
- Preferred contact window — "afternoons", "avoid the rush" — which is one of
  the highest-value things a team can tell itself.
- A map coloured by warmth, filterable, with an "owed" filter for open
  follow-ups. Colour is never the only signal: every pin and badge carries a
  glyph and a text label.
- **Today shows warm contacts within a ten-minute walk.** That is the feature
  that turns a spare twenty minutes into a visit.

### 4. Capture, fast

- **Photograph the sign.** VisionKit's live text scanner reads the storefront,
  the heuristic being that the largest text on signage is the business name
  (because signage is designed to be read from across a street). Hours and phone
  numbers are explicitly excluded — the case that breaks a naive "largest wins".
  All-caps signage is title-cased; a deliberately mixed-case brand is left
  alone.
- **Business cards**, where a job title anchors the person's name on the line
  above it, and a minimalist card falls back to the email domain.
- **Address book import** through Apple's own picker, so no Contacts permission
  is requested at all.
- **Dictation** with `requiresOnDeviceRecognition`. This is the whole feature:
  it works in a basement, in a rural county, and donor conversations never leave
  the phone. A live level meter, because a silent meter is how you discover your
  thumb is over the microphone.
- **GPS check-in**, one-shot and never blocking — if the fix has not arrived in
  six seconds the visit saves without it, because a note without a pin is worth
  far more than a lost note.
- Everything OCR'd lands in an editable field marked "read from a photo, worth a
  glance", and the parser prefers a blank field to a wrong one.

### 5. Offline-first, meant literally

Everything above works with the phone in airplane mode. Nothing in the capture
path touches a network.

- SwiftData locally, always. CloudKit only when a team subscription is on.
- The **in-flight draft is written to disk on every keystroke**
  (`DocumentDraft` + `DraftStore`). A dead battery halfway through signing a
  letter loses nothing, and the app offers to pick it up on next launch.
- Photos and signatures are saved immediately, not held in memory.
- The store opens through **four escalating fallbacks** — intended config,
  local-only, move-the-broken-file-aside-and-start-fresh, memory-only — and
  says which one it used in Settings. A field app that shows a blank screen
  because a migration failed is worse than useless when a donor is waiting.
- `OutboxItem` is a durable queue with exponential backoff that drains on every
  reconnection and every foreground.

#### An honest note about "queue the email for later"

**iOS gives an app no way to send mail without a person.** There is no
background send; `MFMailComposeViewController` needs a foreground presentation
and a configured Mail account. So "queued" here means the *intent* is stored
durably, and the Outbox screen hands the staffer the composers in one batch when
they are back on signal — one tap each at the end of a route, instead of forty
separate acts of remembering.

If an organization wants genuinely unattended sending, `MailTransport` in
`Documents/DocumentExporter.swift` is the seam: implement it against a
transactional mail API, register it at launch, and the outbox drains silently
and the Outbox screen stays empty. Both paths are first class. The app ships
with no implementation on purpose — a field app that requires a backend is a
field app that stops working.

### 6. Lightweight CRM

Contacts creatable from a single field. Visit history, giving history, open
follow-ups, and documents on one screen, ordered for the moment it is actually
read: standing outside the building, thirty seconds before knocking. One-tap
call / text / email / directions. Reminders that arrive at a civil hour (a
midnight due date is scheduled for 9am, a deliberate 4:30pm is left alone) and
carry an action button, because a reminder you can act on from the list is a
reminder that gets done.

A denied notification permission never loses a commitment: the `FollowUp` record
is the source of truth and Today surfaces it regardless.

---

## Monetization

**Free forever, for everyone:**

- Unlimited receipts and acknowledgment letters, both types
- Logo, brand colour, EIN, signature — full branding
- Apple Pay, cash, cheque, in-kind capture
- Contacts, visits, giving history, reminders, kept forever
- Your own warmth ratings and your own map
- Full offline capture, email, AirDrop, printing

**FieldForge Team** ($12.99/month, $119/year, or **$49/year for organizations
under $250k** — offered on trust, nobody audits it):

- Shared organizational memory across the whole staff
- Multiple organizations in one app (fiscal sponsors, consultants)
- Full-colour letterhead, custom footers, per-document signatories
- CSV/bulk export
- Assigning follow-ups to teammates
- Tap to Pay on iPhone

The line is deliberate and there is a test asserting it
(`EntitlementRuleTests`): **nothing a donor's document depends on is ever
paid.** Document generation, the signature, branding, delivery, and the donor's
own records are free, forever, because otherwise a donor's tax letter would
depend on somebody's subscription being current. Team is about *teams and
scale*, which is what only matters once an organization has a budget.

Entitlements are cached locally and **only ever grant on a stale check, never
revoke** — a paying customer whose receipt validation times out on a train keeps
their features.

For a nonprofit that wants to resell this: the tier boundary is one file
(`Monetization/Entitlements.swift`), the product identifiers are three
constants, and there is a `.storekit` configuration file for testing without
App Store Connect.

---

## Project layout

```
ios/FieldForge/
├── project.yml                    XcodeGen spec — the only build config
└── FieldForge/
    ├── App/                       Entry point, DI container, root tabs
    ├── Design/                    Theme tokens + reusable components
    ├── Models/                    SwiftData models, Money, Warmth, draft
    ├── Documents/                 The dual document engine
    │   ├── TaxLanguage.swift        ← the compliance-critical file
    │   ├── PDFLayout.swift          Core Text paginating canvas
    │   ├── ReceiptRenderer.swift
    │   ├── LetterRenderer.swift
    │   ├── DocumentContent.swift    Frozen renderer input
    │   ├── DocumentEngine.swift     Issue / re-issue / re-print
    │   ├── DocumentNumberer.swift
    │   ├── SignatureCapture.swift   Smoothed variable-width ink
    │   └── DocumentExporter.swift   Mail / share / print / transport seam
    ├── Payments/                  Apple Pay, Tap to Pay, manual, gateway seam
    ├── Monetization/              Entitlements, StoreKit 2, paywall
    ├── Services/                  Persistence, reachability, location, OCR,
    │                              speech, contacts, notifications, outbox, sync
    ├── Features/                  One folder per screen area
    └── Resources/Assets.xcassets  Semantic colours, both appearances
```

**Design decisions that shaped the structure**, in case they are not obvious:

- **Money is `Int` cents everywhere.** A half-cent of floating-point drift on a
  tax acknowledgment is not acceptable. `Double` never touches an amount.
- **Enums persist as raw `String`/`Int` with computed accessors.** Costs a few
  lines per model, buys `#Predicate` support on every OS version and graceful
  degradation when an unknown value arrives from a newer build over CloudKit.
- **Every model is CloudKit-compatible by construction** — no `.unique`
  attributes, every property defaulted, every relationship optional. Break any
  of those and the CloudKit-backed container refuses to load.
- **Previews are seeded.** `AppEnvironment.preview()` builds a fully wired
  environment over an in-memory store, so every preview in the project renders
  real data instead of placeholders.

## Accessibility

Not a pass at the end; a constraint throughout.

- **Nothing is a fixed point size.** Every text style is built on a system style,
  so Dynamic Type works to the accessibility sizes. Buttons go multi-line rather
  than truncating.
- **Every tap target is at least 44×44**, and the primary actions are 56pt and
  bottom-anchored — this app is used one-handed while walking.
- **Colour is never the only signal.** Warmth carries a glyph and a label
  everywhere it appears.
- **VoiceOver**: composed labels on rows (a contact row reads as one sentence,
  not six fragments), hints on non-obvious controls, `.isSelected` traits on
  segmented choices, and loading buttons announce "Working" so they are not
  tapped twice.
- **Reduce Motion** is honoured; the attention animation degrades to a haptic
  and a message.
- Both appearances are defined explicitly for all 21 semantic colours, and
  `body` always paints an explicit background.
- Every permission is requested lazily, at the moment the feature is tapped.
  Nothing is asked for at launch, because asking on first run gets a reflexive
  "no".

## Tests

```bash
xcodebuild test -scheme FieldForge -destination 'platform=iOS Simulator,name=iPhone 15'
```

Swift Testing, weighted toward the places where being wrong causes real harm:

| File | What it protects |
|---|---|
| `TaxLanguageTests` | Every IRS substantiation rule, by name |
| `DocumentEngineTests` | Both templates render; snapshots stay frozen; **unconfirmed payments and pledges are refused** |
| `MoneyTests` | Exact cent arithmetic; the amount parser against what thumbs type |
| `DocumentNumbererTests` | Readable numbers, year rollover, offline collision avoidance |
| `WarmthTests` | Recency weighting; `doNotReturn` is absolutely sticky |
| `ContactParserTests` | OCR heuristics, including the hours-bigger-than-the-name case |
| `DraftAndGiftRuleTests` | Giving totals, draft resume round-trip, outbox backoff |

---

## Remaining work

Honest list. Nothing here blocks a first build or a TestFlight round.

### Needs an Apple Developer account (cannot be done in code)

1. **Merchant identifier.** Create `merchant.<your-bundle-id>` in the developer
   portal and put it in `App/FieldForge.entitlements` and
   `PaymentGatewayRegistry`.
2. **CloudKit container.** Create `iCloud.<your-bundle-id>`, then deploy the
   schema to production before shipping — SwiftData creates it in development on
   first run, and a build that has not deployed it will silently fall back to
   local-only.
3. **StoreKit products.** Create the three subscriptions in App Store Connect
   with the identifiers in `StoreService.ProductID`. Until then the paywall
   correctly reports the store as unreachable and everything else works.
4. **App icon.** `Assets.xcassets/AppIcon.appiconset` has the manifest but no
   1024×1024 image.

### Wiring a processor

Apple Pay gives you an encrypted token, not money. Implement the endpoint that
`HostedProcessorGateway` posts to — a dozen lines with any processor's server
SDK — and register it at launch:

```swift
PaymentGatewayRegistry.shared.configure(
    gateway: HostedProcessorGateway(
        endpoint: URL(string: "https://donations.example.org/api/charge")!,
        organizationPublicKey: "pk_live_…"
    ),
    merchantIdentifier: "merchant.org.example.fieldforge"
)
```

The endpoint holds the processor secret, which keeps the app out of PCI scope
entirely — it never sees a card number. **Honour the `Idempotency-Key` header**;
it is what makes a retry after a dropped response safe rather than a
double-charge.

Until this is done, debug builds use `SimulatedProcessorGateway`, which refuses
to operate in release and puts a red banner on Today and in Settings. A
simulated payment producing a real-looking tax receipt would be a genuinely
harmful bug, so the guard is a hard failure rather than a warning.

### Wiring Tap to Pay

1. Request `com.apple.developer.proximity-reader.payment.acceptance` from Apple.
2. Uncomment the key in `FieldForge.entitlements` (leaving it in without the
   grant fails code signing).
3. Add `TAP_TO_PAY_ENABLED` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
4. Conform a wrapper around your payment platform's SDK to `TapToPayBackend` —
   three methods — and pass it to `PaymentCoordinator`.

### Genuinely unfinished

- **Team sharing is currently "your devices only."** SwiftData mirrors whole
  models to the user's *private* CloudKit database, which is correct and is how
  their iPhone and iPad stay in step. Sharing across a *team* needs a shared
  zone, and sharing these models directly would expose `privateNotes` — which
  the app promises never leaves the device. The fix is a narrow
  `SharedContactRecord` model holding only the fields in
  `SyncEngine.sharedPreview`, written to the shared zone, with no counterpart
  for private notes so they cannot leak. Until that exists the Team screen says
  what is actually happening rather than overclaiming. This is the single
  largest remaining piece.
- **Bulk CSV export** is gated and described on the paywall but not implemented.
- **In-kind photo attachment** has full model and thumbnail support; the capture
  flow tells the staffer to add it from the contact record afterwards rather
  than offering a camera button inline.
- **Voice note audio** is transcribed but the `.m4a` is not retained — only the
  text. `AttachmentKind.voiceNote` exists for when it should be.
- **Notification actions** ("Mark done", "Remind me in a week") are registered
  but no `UNUserNotificationCenterDelegate` handles the taps yet, so they
  currently just open the app.
- **Localisation.** All strings are inline English. `SWIFT_EMIT_LOC_STRINGS` is
  on, so extraction is a build away, but a Spanish-language outreach team is a
  very plausible first request.
- **A UI test** for the four-step capture flow. The logic underneath is covered;
  the flow itself is not.

### Most likely to need a nudge on first compile

Ranked by how much I would bet against them:

1. `PDFLayout.swift` — the Core Text flip and the `CTFrameGetVisibleStringRange`
   page-break loop. The logic is standard, but the coordinate reconciliation
   between UIKit's top-down PDF context and Core Text's bottom-up drawing is
   exactly the kind of thing worth eyeballing on a real render.
2. `LiveTextScanner`'s normalisation of `RecognizedItem.bounds` (a view-space
   quadrilateral) into Vision's normalised bottom-left-origin box. The sign
   parser's "largest text" heuristic depends on getting this right.
3. `PKPaymentAuthorizationControllerDelegate` isolation. It uses
   `nonisolated` + `MainActor.assumeIsolated`, which is correct for PassKit's
   actual threading, but strict-concurrency settings could complain.
4. SwiftData `#Predicate` shapes — particularly the nil-coalescing one in
   `OutboxProcessor.purgeCompletedItems`.
5. `Map(position:selection:)` with tagged `Annotation` content.

---

FieldForge is not a tax adviser. The language on its documents follows IRS
Publication 1771, and the app says so on every page, but the issuing
organization is responsible for what it issues.
