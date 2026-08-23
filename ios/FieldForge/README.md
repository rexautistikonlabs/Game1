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

## Running it on a device

### 1. Generate the project

There is no `.xcodeproj` in the repository — a generated project file is a merge
conflict waiting to happen. Use [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd ios/FieldForge
xcodegen generate
open FieldForge.xcodeproj
```

Every `.swift` file under `FieldForge/` is picked up by a recursive glob, so new
files need no project surgery — regenerate and they are in the target.

**Requirements:** Xcode 15.3 or newer, iOS 17.0 deployment target, Swift 5
language mode. One Swift package: **Stripe Terminal**, used only for Tap to Pay
on iPhone. It is never initialised at launch, and it is never called unless
Apple has granted the Tap to Pay entitlement. Apple Pay does not use it.

### 2. Set your team and bundle identifier

In `project.yml`:

```yaml
DEVELOPMENT_TEAM: 964M77TDXU            # Rex Autistikon Research Foundation
PRODUCT_BUNDLE_IDENTIFIER: org.rexautistikonlabs.fieldforge
```

Then re-run `xcodegen generate`. Merchant and CloudKit identifiers live in
`FieldForge/App/FieldForge.entitlements` and must match the Developer portal:

```
merchant.org.rexautistikonlabs.fieldforge
iCloud.org.rexautistikonlabs.fieldforge
```

The same CloudKit container name is used in `Services/Persistence.swift`,
`Services/SharedWarmth/SharedWarmthService.swift`, and `Features/Settings/TeamView.swift`.

### 3. Run it

Select your iPhone, hit ⌘R. On first launch Xcode will ask to trust the
developer certificate on the device (Settings → General → VPN & Device
Management).

**What works immediately, with no account setup at all:** capture, OCR,
dictation, GPS check-in, both document types, signatures, email/AirDrop/print,
the CRM, the map, follow-ups and route mode. This is the majority of the app,
and it works in airplane mode.

**What needs Apple Developer configuration** is listed under
[Remaining work](#remaining-work) — iCloud team sharing and subscriptions each
need a portal identifier before they do anything. Donors pay via a **text or
email pay link**. In-person Wallet charge is off so staff cannot charge this
iPhone’s Wallet by mistake. Other nonprofits tap **Connect Stripe** in Settings
so pay-link funds land on *their* Stripe. They never see Azure, merchant IDs,
or secret keys. No `sk_` on iOS. No CloudKit at launch.

### If you would rather not use XcodeGen

Create an iOS App target named `FieldForge`, drag the `FieldForge/` folder in as
a folder reference, and set:

- `INFOPLIST_FILE` → `FieldForge/App/Info.plist`
- `CODE_SIGN_ENTITLEMENTS` → `FieldForge/App/FieldForge.entitlements`
- `IPHONEOS_DEPLOYMENT_TARGET` → `17.0`, `SWIFT_VERSION` → `5.0`
- Exclude `App/Info.plist`, `App/FieldForge.entitlements` and
  `Monetization/Products.storekit` from **Copy Bundle Resources**. Leaving the
  Info.plist in there is a hard build failure ("Multiple commands produce…"),
  and shipping your entitlements file inside the app is a needless disclosure.

### Running the tests

```bash
xcodebuild test -scheme FieldForge \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

Or ⌘U in Xcode. The suite is pure logic and rendering — no network, no
CloudKit, no simulator permissions — so it runs clean on a fresh checkout.

> **Still not compiled here.** This was written in a Linux container with no
> Swift toolchain, so the first build is a first build. What has been verified
> statically across all 97 files: delimiter balance, no duplicate top-level
> declarations, no unresolved type references, every framework import present
> for the symbols each file uses, every `Color("…")` resolving to a real asset,
> every `#Predicate` in an expressible shape, and no `ViewBuilder` block over
> the ten-child limit. Known Xcode-15 incompatibilities have been removed
> (`@Previewable`), and the two classic build-stoppers — an Info.plist copied
> as a bundle resource and an empty AppIcon set — are fixed. Expect a handful
> of signature and inference fixes, not a rewrite; the files most likely to
> need one are ranked under [Remaining work](#remaining-work).

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

**Branding.** Four finished letterhead designs rather than a pile of toggles —
classic, colour band, split, and minimal (for printing onto stationery that
already has a letterhead). Four body typefaces, drawn from the font *designs*
built into iOS rather than licensed font files: shipping a typeface is a legal
question the app cannot answer for a user, and a missing font at render time
would be a blank page in front of a donor. Four footer options, from
legal-minimum to name-EIN-and-mission.

Logo, brand colour, letterhead lines, EIN, tagline and signature are free
forever; the colour-band and split letterheads, the richer footers and
per-document signatories are paid. Both free styles still produce a document
nobody would be embarrassed to hand over — that is the test any free tier here
has to pass.

**In-kind photographs** can be rendered into the acknowledgment letter, placed
after the gift summary and before the tax paragraph: the summary says "42
blankets", the photographs show them, and the substantiation language has the
last word. The caption is careful, because a photograph next to a number could
easily read as the charity valuing the property — exactly what `TaxLanguage` is
at pains not to do. Any value shown is labelled as the donor's own estimate.

**Void and revision.** A void keeps the document, its number and its PDF, and
requires a reason — "voided, no reason given" is the least useful entry an audit
trail can hold. Deleting would be wrong twice over: the donor may be holding a
printed copy, and a gap in the numbering looks like a cover-up. Every document
carries an append-only `DocumentAuditEntry` trail — issued, sent, queued,
failed, printed, shared, voided, superseded — and the three delivery
transitions append to it *inside the same call* that changes the state, because
there are eight places in the app that mark a document sent and a delivery
without a trail entry is a delivery nobody can prove.

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

- **Text pay link** and **Email pay link** — the donor path. Gift step has
  amount plus the contact’s phone and email. Both buttons ask Azure
  (`POST /api/create-payment-link`) for a Checkout URL using `STRIPE_SECRET_KEY`
  on the function, never on the iPhone, then reuse the returned `url`.
  **Text pay link** opens Messages (`MFMessageCompose` or `sms:`) with
  `{Org} — tap to give ${amount}: {url}`. **Email pay link** opens Mail
  (`MFMailComposeViewController`, fallback `mailto:`) with
  To: contact email, Subject: `{Org} — gift of ${amount}`, Body: a short note
  plus the url. Phone and email can both exist; staff can send one or both.
  Sending twice may create two Checkout sessions — the gift stores the latest
  `sessionId` and status checks that one. If the contact has no number or no
  email, the app asks for it and saves it on the Contact. The gift stays unpaid
  until Stripe reports `succeeded`. v1: pull-to-refresh or **I got paid** /
  **Mark paid** GETs session status from Azure. A letter is issued only after
  that. No CloudKit at launch.
- **In-person Wallet charge is off.** Capture does not present
  `PKPaymentAuthorization` or “Pay with this iPhone’s Wallet.” Azure
  `POST /api/create-payment-intent` stays deployed; the UI does not call it.
  Settings may still show Stripe backend + `pk_` as platform config.
- **Connect Stripe** — other nonprofits tap **Settings → Connect Stripe**
  (Express OAuth). FieldForge stores `acct_…` in the Keychain. Azure creates the
  pay link with `Stripe-Account` so funds land on *their* Stripe. No connected
  account charges the platform (current Rex test behavior). Downloading orgs
  never see Azure, merchant IDs, CSRs, or secret keys.
- **Tap to Pay on iPhone** — selecting the tile is not a charge. **Collect**
  (or Next on What) starts Stripe Terminal: Azure `POST /api/connection-token`
  → `{ secret, locationId }` (and a `card_present` PaymentIntent when amount is
  sent), then Apple’s terms / reader discovery the first time, then **Hold card
  to top of iPhone**. Discovery never starts at launch. A missing Terminal
  location alerts *“Create a Terminal location in Stripe Dashboard and set
  STRIPE_TERMINAL_LOCATION_ID on Azure.”* (Stripe Dashboard → Terminal →
  Locations) and does not call `discoverReaders`. Gift is received only after
  PaymentIntent `succeeded`. Cancel, fail, timeout, or a Stripe/Apple discovery
  error stay on What with the gift unpaid — no letter, no crash. Simulator or a
  missing Apple grant alerts *“Tap to Pay needs a registered iPhone and Apple
  development entitlement”* and stays on What. **Development devices only.** Do
  not send Apple review videos until this collect UI actually opens on a
  physical iPhone. See [TAP_TO_PAY.md](TAP_TO_PAY.md).
- **Manual** — cash, cheque, in-kind, recorded card (last 4 only), pledge.
  Unchanged, first-class, and fully offline. Next can proceed; a next action is
  still required at visit end.

**Document gating.** Tap to Pay, text pay link, and email pay link cannot leave
What for Document until Stripe `payment-status` or Terminal reports succeeded.
Cash, check, in-kind, pledge, recorded card, and other may proceed. A tax letter
still requires Gift received/deposited, and for card / link / Tap to Pay,
Stripe `succeeded`.

Amount, date, card description and payer name auto-populate from a cleared
payment, and the amount field locks — so what the donor was charged and what the
document says can never disagree.

### 3. The Warmth System

A four-point rating (plus a deliberately separated "do not contact again"),
tapped once at the end of every interaction. Twenty documented "not today"s are
how the twenty-first door opens.

- **Red → amber → olive → green.** A sequential ramp anyone reads instinctively
  on a map. "Do not contact" sits deliberately *off* the ramp in purple, because
  it is a hard stop rather than "very cold" — and because that keeps it
  distinguishable from the red end for the viewers a red-green ramp serves
  worst. Every indicator also carries a glyph in an unambiguous progression
  (`minus` → `equals` → `plus` → `star`), so the scale reads identically with
  the colour removed. The map has a colour key.
- Contact-level warmth is a **recency-weighted roll-up** of every visit rating,
  with a one-year half-life, so a business that was cold in 2019 and warm last
  week reads as warm. `doNotReturn` is absorbing.
- Preferred contact window — "afternoons", "avoid the rush" — which now also
  drives *when reminders fire* (see §5).

#### Shared Warmth, and how private notes stay private

The paid tier shares warmth, giving history and team notes across a whole staff
over a **CloudKit shared record zone**. A zone-level `CKShare` rather than
per-record shares: a team shares one zone, everyone in it reads and writes, and
adding a teammate does not mean re-sharing 400 records. Invites go through
`UICloudSharingController`, so it is the sharing sheet people already know from
Photos.

Private notes never leave the device, and that is enforced four independent
ways — three of them at compile time:

1. **`SharedContactProjection` has no field for private notes.** Not an empty
   one, not an optional one — none. Nothing that reads a `Contact` and writes a
   projection can carry them, because there is nowhere to put them.
2. **The CloudKit record is built from the projection, never from a `Contact`.**
   `apply(to:)` is a method on the projection, so the networking layer cannot
   see a private field even by accident.
3. **The two live in physically separate store files**, each with its own
   `ModelConfiguration`. The bytes that sync and the bytes that must not sync are
   different files on disk.
4. **A test asserts it.** `SharedWarmthPrivacyTests` writes a sentinel string
   into every private field, projects, builds the record, walks *every key
   actually present*, and fails if the sentinel appears anywhere.

The Team screen shows both halves of the payload — what leaves and what stays —
generated from the same `Key.all` list the record builder uses, so the
disclosure cannot drift away from the truth.

Two merge rules worth knowing: last-writer-wins on `updatedAt`, except
`isDoNotContact`, which is **sticky**. If anybody on the team has been told to
stop contacting someone, a staler record cannot undo it.

### 4. Capture, fast — and one-handed

The design target is explicit: **any capture reachable in two taps, and the
common one in one.**

- **Quick Capture.** A tap opens the flow. A long press fans out three
  shortcuts — scan a sign, scan a card, or return to the last contact — each of
  which is the second tap. The fan opens upward and *inward*, into the arc a
  thumb sweeps without the hand changing grip, rather than toward the top of the
  screen where a thumb on a 6.7" phone cannot reach at all. Left-handed users
  get the whole control mirrored via a stored preference, and VoiceOver users
  get the shortcuts as accessibility actions, because a long press is not
  discoverable with the screen curtain on.
- **One-action scan.** Scan a sign, tap Use, and the contact *and* the visit are
  already saved, GPS-stamped, with the photograph attached as evidence — and the
  flow opens on the gift step in case money changed hands. That is two
  interactions for what used to be five. The safety property that makes
  committing this early acceptable: nothing in that path is destructive and
  everything is editable, so a bad OCR read produces a correctable contact
  flagged "scanned", not a wrong tax document.
- An existing record is matched rather than duplicated, and a match says "Back
  at Delgado Hardware" instead of "Added" — which is a much better thing to
  read. Duplicate detection is deliberately conservative in one direction: a
  false *match* silently merges two businesses, which is worse than a false
  *miss* that leaves a duplicate somebody can merge later.
- **Business cards** where a job title anchors the person's name on the line
  above it, and a minimalist card falls back to the email domain.
- **Dictation** with `requiresOnDeviceRecognition` — it works in a basement and
  donor conversations never leave the phone.
- **GPS check-in**, one-shot and never blocking: if the fix has not arrived in
  six seconds the visit saves without it, because a note without a pin is worth
  far more than a lost note.

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

### 6. Lightweight CRM and the follow-up engine

Contacts creatable from a single field. Visit history, giving history, open
follow-ups, documents, and the team's view of the same contact on one screen,
ordered for the moment it is actually read: standing outside the building,
thirty seconds before knocking.

- **One-tap Call / Text / Email / Directions / Schedule / Remind.** "Schedule"
  creates a visit reminder in one tap, with no sheet and no date picker — a week
  out, snapped to the hour that contact is actually catchable.
- **Reminders fire at the right time of day.** A bare date on a contact whose
  window is "after the lunch rush" fires at 2pm, not 9am. A lunch-hour contact
  fires at 11:45, *before* the window, so there is time to walk there. A time
  the staffer chose on purpose is never moved. The notification says why it
  arrived now, which is what makes good timing read as deliberate rather than
  random.
- **Route mode** (paid) orders today's follow-ups by walking distance: nearest
  neighbour plus 2-opt, which gets within a few percent of optimal on a dozen
  stops in well under a millisecond, entirely offline. Straight-line distance,
  not street routing — street routing needs a network and this has to work in a
  basement, and over a few blocks the crow-flies order and the walking order
  agree. The screen is built around the *current stop*, not the list, because
  that is how it is used: phone held low, glanced at between buildings. Marking
  a stop done completes its follow-up, and does **not** reshuffle the remaining
  order — a staffer mid-street has already decided where they are walking.
- Warm contacts near the route are folded in, which turns a four-stop errand
  into a productive afternoon.

A denied notification permission never loses a commitment: the `FollowUp` record
is the source of truth and Today surfaces it regardless.

### 7. The Today screen

Rebuilt around one question — **what should I do in the next ten seconds?** —
and ordered by urgency rather than by category:

1. Anything broken: setup missing, storage degraded, documents stuck.
2. **Who to see today.** One ranked list, not three competing ones. Overdue
   commitments, then due-today, then warm contacts within a ten-minute walk,
   then warm contacts not seen in nine months (quietly the most valuable
   category in fundraising and the easiest to forget). Every row shows *why it
   is on the list* — an ordering nobody can explain is an ordering nobody
   trusts — and ties break by distance, which is what saves actual walking.
3. Route mode, offered only when there are at least two routable stops. A route
   button that produces a one-stop route is worse than no button.
4. Today's numbers, small, including the conversion rate a development director
   will ask about.
5. What the team has been doing.
6. Recent activity, so a mistake is easy to find.

The "who to see" empty state has four variants, because the right thing to say
depends entirely on why the list is empty: no contacts at all, still locating,
location denied, or genuinely nothing owed.

---

## Monetization

**Free forever, for everyone:**

- Unlimited receipts and acknowledgment letters, both types
- Logo, brand colour, EIN, signature — full branding
- Pay by link, cash, cheque, in-kind capture
- Contacts, visits, giving history, reminders, kept forever
- Your own warmth ratings and your own map
- Full offline capture, email, AirDrop, printing

**FieldForge Team** ($12.99/month, $119/year, or **$49/year for organizations
under $250k** — offered on trust, nobody audits it):

- Shared Warmth: one memory across the whole staff, over a CloudKit shared zone
- Route mode: today's follow-ups in walking order
- Multiple organizations in one app (fiscal sponsors, consultants)
- Colour-band and split letterheads, richer footers, per-document signatories
- Searching document history past 18 months
- CSV/bulk export
- Assigning follow-ups to teammates
- Tap to Pay on iPhone

**On the history limit, specifically.** The free tier's Documents list shows the
last **18 months** — not three. That is deliberate, and it is the difference
between a limit and a hostage: 18 months covers the whole of last tax year plus
the current one, which is the window a donor actually calls about. A nonprofit
that never pays a penny can still answer every realistic "can you resend my
receipt from April?".

Nothing is ever deleted. The cap limits what the list *shows*, the Documents
screen carries a row naming exactly how many older documents exist, and it says
they are still on the iPhone. A lapsed subscription puts them back behind the
window they came from; it never makes a donor's tax record unreachable.

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
    │   │                          speech, contacts, notifications, outbox,
    │   │                          route planning
    │   └── SharedWarmth/          CloudKit shared-zone sync + sharing sheet
    ├── Features/                  One folder per screen area
    │   ├── Capture/                 4-step flow, Quick Capture, one-shot scan
    │   ├── Route/                   Route mode
    │   └── …
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
| `SharedWarmthPrivacyTests` | **The private-notes guarantee** — sentinel strings, every CloudKit key walked, merge stickiness, store separation |
| `RoutePlannerTests` | Route ordering on known geometry, distance consistency, progress |
| `ReminderTimingTests` | Time-of-day scheduling; never fires in the small hours |
| `AuditAndGatingTests` | Audit trail completeness, void semantics, the free/paid line, letterhead migration, the unbuilt-feature guard |
| `PaymentIntentTests` | Secret keys never stick; Apple Pay uses the platform origin; Connect is `acct_` only; tax letters wait for `succeeded` (Apple Pay, Tap to Pay, text/email pay link); SMS and email copy have no `sk_` |
| `PDFPaginationTests` | Real PDFs through the real templates: multi-page letters with photos, every letterhead × typeface × footer combination, receipts staying to one page |
| `CSVExporterTests` | RFC 4180 quoting against adversarial donor names, BOM and CRLF, private notes excluded from a shareable export |
| `OpenDoorPrivacyTests` | Open Door invite copies place facts only; warmth and amounts cannot appear |
| `CourtesyPrivacyTests` | Courtesy pings and projections cannot carry private notes, amounts, or warmth |
| `CrewLedgerTests` | Staff-only points, streak badge, bank qualifier is not an amount |
| `InKindMatcherTests` | Same category + ZIP / ZIP3; closed needs ignored |
| `PlaybookTests` | Default ZIP 32221; come-back Tuesdays; route prefers playbook-today |
| `ProofPacketTests` | Audit/delivery packet; imported letter keeps an IRS cover |

---

## Six field-work pillars (v1)

FieldForge is the doorstep operating system for in-person nonprofit asks. Payment platforms can still take the card. These six layers sit on top of capture, letters/receipts, warmth, map, route, and outbox.

### What is fully local (this iPhone / this org)

| Pillar | What ships in v1 |
|---|---|
| **Open Door map** | `OpenDoorListing` is visible only if opted in. Private visit pins stay on the staffer's device. Invite-from-visit creates a **local draft** plus shareable explanation text. Org-local “mark as opted in” is manual — nothing is scraped. |
| **Letter + receipt as trust** | Proof packet = issued PDF + in-kind photos + audit trail + delivery state, shared as one combined PDF. Imported premade letters attach **after** a generated IRS cover; built-in substantiation language is never shortened. |
| **In-kind logistics** | `InKindNeed` and `InKindOffer` (leftover inventory checkbox on an in-kind conversation). Match is same category + same ZIP or neighbouring ZIP3. No checkout. |
| **Crew sport** | Staff-only points: visits, letters/receipts issued, follow-ups closed, proof packets shared, in-kind offers logged. Streaks and badges. Never donors, amounts, or warmth as a public score. |
| **City playbook** | Best day-part, “ask for Dana”, result of last ask, next-ask-after, ZIP. Default focus ZIP **32221** (editable in Settings). Map ZIP filter. Route prefers “come back Tuesdays” when today matches. Today lists “due in this ZIP”. |
| **Inter-org courtesy** | `CourtesyPing` + `SharedCourtesyProjection`. Off-by-default toggle. Allowed: place name, ZIP / approximate pin, date only, courtesy-until, alreadyVisited / doNotStackAsk. |

### What needs a future backend / network

- **Public Open Door directory** — v1 listings are org-local. A city-wide opted-in map needs a server (or a CloudKit public database) and a real claim/opt-in flow. Not scraped.
- **Live courtesy network** — v1 stores pings locally and marks them “ready to share when team courtesy is enabled.” `CourtesyService.isLiveCourtesyNetworkAvailable` is `false`. Do not treat the projection store as a live city feed.
- **Team crew board** — points are per signed-in staffer on this device. Teammate totals need the existing shared-zone work plus a second projection type.

Shared Warmth (team memory of warmth/giving) remains the paid CloudKit shared zone it already was. Courtesy is a **narrower** projection and is not that zone.

### Privacy guarantees

A business is never published from a private visit. Open Door listings and courtesy pings are built from named allow-lists: no path copies `privateNotes`, gift amounts, warmth, donor phone/email, or staff commentary onto those types. Private visit pins, playbook notes, and crew scores stay on-device unless the org later opts into a real courtesy network. Tests (`OpenDoorPrivacyTests`, `CourtesyPrivacyTests`) write sentinel strings into private fields and fail if they appear on a listing, ping, or CloudKit record.

---

## Remaining work

Honest list. Nothing here blocks a first build or a TestFlight round.

### Needs an Apple Developer account (cannot be done in code)

1. **Merchant identifier.** Done for this app:
   `merchant.org.rexautistikonlabs.fieldforge` (Stripe Apple Pay cert active).
2. **CloudKit container.** Create `iCloud.<your-bundle-id>`, then deploy the
   schema to production before shipping — SwiftData creates it in development on
   first run, and a build that has not deployed it will silently fall back to
   local-only.
3. **StoreKit products.** Create the three subscriptions in App Store Connect
   with the identifiers in `StoreService.ProductID`. Until then the paywall
   correctly reports the store as unreachable and everything else works.
4. **App icon.** `Assets.xcassets/AppIcon.appiconset` has the manifest but no
   1024×1024 image.

### Wiring Stripe (pay link + PaymentIntent)

Merchant ID `merchant.org.rexautistikonlabs.fieldforge` is already in the
entitlements. In-person Wallet charge is off in capture. Donors pay through
**Text pay link** or **Email pay link** only.

The platform owns Azure, the merchant ID, the Apple Pay cert, and
`STRIPE_SECRET_KEY`. Downloading orgs never see those.

1. Deploy `azure-function/` (Node 20). Set on the Function App:
   - `STRIPE_SECRET_KEY` — `sk_test_...` or `sk_live_...`. Never put that in iOS.
   - `STRIPE_PUBLISHABLE_KEY` — `pk_test_...` / `pk_live_...` (the iPhone fetches
     this; orgs never type it).
   - `STRIPE_CLIENT_ID` — `ca_...` for Connect Express OAuth.
   - `STRIPE_CONNECT_REDIRECT_URI` —
     `https://<app>.azurewebsites.net/api/connect/oauth/callback`
     (also add that URI in the Stripe Dashboard Connect OAuth settings).
2. **Normal Settings is Connect Stripe only.** Other nonprofits tap that,
   finish Express onboarding, and FieldForge stores `acct_…` in the Keychain.
   Azure then creates the pay link or PaymentIntent with the `Stripe-Account`
   header so funds land on *their* Stripe. No connected account → platform
   account (Rex test behavior).
3. Backend URL and `pk_` fields are hidden behind a platform/debug control
   (DEBUG builds, or seven taps on **Settings → Version**). Empty URL uses
   `https://fieldforgepay-a7hxe0h0dmcqaneu.eastus-01.azurewebsites.net`. A stored override still wins, so
   the pay-link path for downloading orgs is unchanged.

Charge routes (same `STRIPE_SECRET_KEY`, never in iOS):

- **`POST /api/create-payment-link`** `{ amount, giftId, contactName }` →
  `{ url }`. Optional `stripeAccount`. This is the donor SMS and email path.
  Capture calls this.
- **`POST /api/create-payment-intent`** `{ amount }` → `{ clientSecret }`.
  Optional `stripeAccount`. Optional `method: "tap_to_pay"` mints a
  `card_present` intent for Terminal. Staff Wallet capture does not call it.
- **`POST /api/connection-token`** → `{ secret, locationId }`. Optional
  `amount` (usd cents) also returns `{ clientSecret }` for a Terminal
  PaymentIntent. Optional `stripeAccount`. Requires a Terminal location
  (`STRIPE_TERMINAL_LOCATION_ID`, created at Stripe → Terminal → Locations).
  Redeploy `azure-function/` after changing this.

v1 staff confirmation: **`GET /api/payment-status?sessionId=`** (or `giftId`).
Amounts under 50 cents or over 10_000_000 cents are rejected. Card
`4242 4242 4242 4242` is the Stripe test charge; see
`azure-function/README.md`.

CloudKit is not opened at launch and is not used for payment settings. Secret
keys never sit on iOS. No QR codes in this pass.

### Wiring Tap to Pay

**Development devices only.** Do not send Apple Tap to Pay videos until Collect
actually opens the hold-card UI on a physical iPhone.

Needs **both** the Apple entitlement and Stripe Terminal. Simulator and a
missing grant alert *“Tap to Pay needs a registered iPhone and Apple
development entitlement”* and stay on What. See [TAP_TO_PAY.md](TAP_TO_PAY.md).

The iOS app **does not** hardcode Terminal location ids or secret keys. Location
comes from Azure env `STRIPE_TERMINAL_LOCATION_ID`. `sk_` never sits in Settings.

1. Request `com.apple.developer.proximity-reader.payment.acceptance` from Apple.
2. The key is in `FieldForge.entitlements` for development signing. A missing
   grant must not crash — collect is refused before Terminal APIs run.
3. Stripe Terminal is already the app's one Swift package. It is not
   initialised at launch. Collect is the only entry.
4. Azure Function App `fieldforgepay`: keep `STRIPE_SECRET_KEY` (existing test
   key). Set `STRIPE_TERMINAL_LOCATION_ID` from Stripe Dashboard → Terminal →
   Locations. `POST /api/connection-token` returns `{ secret, locationId }` and
   mints the token with that location; 400 if the env is missing. A tap-to-pay
   PaymentIntent (optional `amount` on that route, or `method: "tap_to_pay"` on
   `create-payment-intent`) carries the same location. Pay-link routes are
   unchanged.

#### End-to-end on a registered iPhone

`discoverReaders` aborted (SIGABRT / `pthread_kill`) when it ran on the main
thread with the amount keyboard still up, then finished twice. Stripe / Apple
Tap to Pay also throw **NSException** while presenting UI; Xcode **All
Exceptions** stops there even though FieldForge catches them.

1. Set `STRIPE_TERMINAL_LOCATION_ID` on Azure `fieldforgepay` (the Test
   Terminal location already created in the Dashboard). Never put that id in
   the iOS project.
2. Republish `azure-function/`.
3. Stop Xcode. Disable **All Exceptions**. Delete FieldForge from the iPhone.
4. Install this build and **launch from the icon** (no debugger).
5. Capture → gift → **Tap to Pay** → **Collect**. First run accepts Apple /
   Stripe Tap to Pay terms. Hold a **physical contactless card** to the **top
   of the phone**.
6. Gift is received only after PaymentIntent `succeeded`; then Document is
   allowed. Cancel / fail stay on What. Today always paints (collect-in-flight
   is cleared at launch). CloudKit is not opened at launch.

Staff Wallet stays off. Text and email pay links stay. See
[TAP_TO_PAY.md](TAP_TO_PAY.md).

### Genuinely unfinished

- **Assigning follow-ups to a teammate.** Warmth, notes and giving history sync
  today; handing a specific reminder to a named colleague does not, because the
  shared zone carries contact projections only and the sync loop is typed to
  them in fourteen places. Delivering it means a second projection type with the
  same four-mechanism privacy discipline — real work, not a toggle.

  Rather than ship a control that quietly does nothing, `Feature.isAvailable`
  marks it unbuilt: `isEnabled` returns false even for a paying customer, the
  paywall filters it out of what it sells, and the Team screen says plainly that
  it is missing. A test asserts that exactly one feature is in that state, so
  the flag cannot quietly become a dumping ground.

- **The app icon is a placeholder** — a generated teal chevron, good enough to
  find on a home screen during testing and obviously provisional to a designer.

- **Localisation.** All strings are inline English. `SWIFT_EMIT_LOC_STRINGS` is
  on so extraction is a build away, but a Spanish-language outreach team is a
  very plausible first request.

- **A UI test** for the four-step capture flow. The logic underneath is covered;
  the flow itself is not.

### Most likely to need a nudge on first compile

Ranked by how much I would bet against them:

1. **`SharedWarmthService`** — the CloudKit async surface
   (`recordZoneChanges(inZoneWith:since:)`, `modifyRecords(saving:deleting:)`,
   `CKShare(recordZoneID:)`). The shapes are right for iOS 17, and the zone-wide
   share is now looked up by `CKRecordNameZoneWideShare` rather than
   `CKRecordZone.share`, but this is the file to put a breakpoint in first.
2. **`PDFLayout.usedHeight(of:in:)`** — the Core Text line-origin arithmetic
   that replaced the old re-measure. It is the correct approach and also the
   fiddliest twenty lines in the project.
3. **`ItemCameraView`** on a device: `UIImagePickerController` with `.camera`
   needs a real camera, so it is untestable in the simulator by definition.
4. **`Map(position:selection:)`** with tagged `Annotation` content, and
   `MapPolyline` in route mode.
5. **`DataScannerViewController.capturePhoto()`** inside the `onReady` escape
   hatch — the closure captures the scanner, which is correct but worth
   confirming does not retain it past dismissal.

---

FieldForge is not a tax adviser. The language on its documents follows IRS
Publication 1771, and the app says so on every page, but the issuing
organization is responsible for what it issues.
