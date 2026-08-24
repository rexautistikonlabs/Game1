# Tap to Pay on iPhone

FieldForge can take a contactless card on this iPhone via **Stripe Terminal**.
Selecting the Tap to Pay tile is not a charge. **Collect** (or Next on What)
starts Terminal collect.

## It ships off

**Settings → Payments → Tap to Pay on iPhone is off in a fresh install.** The
donor pay link — text or email, paid on the donor's own phone — is the primary
card path and needs nothing on this iPhone.

`discoverReaders` has aborted the process (SIGABRT / `pthread_kill`) on some
device and profile combinations, and a crash in the middle of capture costs a
gift. Rather than ask a staffer to find that out in front of a donor, the
feature sits behind a switch an operator flips only after a real contactless
card has worked on that phone.

While the switch is off, nothing in the app reaches `StripeTerminal`:

| Where | What happens |
| --- | --- |
| Method tile | Present, disabled, captioned **Off**. `select(_:)` refuses a disabled tile, so Collect is unreachable. |
| `TapToPayProvider.availability()` | `.tapToPayTurnedOff` |
| `TapToPayProvider.collect(_:)` | Refuses with `tap-to-pay-off`, before every other check |
| `ensureLiveBackendIfNeeded()` | Returns without constructing `StripeTerminalTapToPayBackend` |

Stored per device as `fieldforge.stripe.tapToPayEnabled` in `UserDefaults`.
An absent key means off — it is never defaulted on, in any build configuration.

## When it is on

That path is gated on two more things, both of which must be true at runtime:

1. Apple entitlement `com.apple.developer.proximity-reader.payment.acceptance`
2. Stripe Terminal SDK (already linked in `project.yml`)

**Development devices only.** Do not send Apple review videos until Collect
actually opens the hold-card UI on a physical iPhone.

On Simulator, or when the signed profile lacks the grant, Collect alerts:

> Tap to Pay needs a registered iPhone and Apple development entitlement

and stays on What. The app **must not crash**. Stripe Terminal Tap to Pay APIs
are never called unless the signed entitlement is present.

Donors can still pay via a text or email pay link. In-person Wallet charge is
off so staff cannot charge this iPhone by mistake. Cash, checks, in-kind,
pledges, and recorded card (last 4) stay. A tax letter is issued only after the
gift is received or deposited, and for Tap to Pay / pay link only after Stripe
reports `succeeded`.

## Collect

1. Azure `POST /api/connection-token` → `{ secret, locationId }` using
   `STRIPE_SECRET_KEY` on the function, never on the iPhone. Optional `amount`
   (usd cents) also returns `{ clientSecret }` for a Terminal `card_present`
   PaymentIntent. The function **must** send a location id. Collect will not
   call `discoverReaders` without one.
2. First time on a phone: Apple Tap to Pay terms and reader discovery
   (Stripe Terminal + ProximityReader). Discovery never starts at launch.
3. Prompt: **Hold card to top of iPhone**. Wait. 60 seconds, then discovery
   and collect cancel and the gift stays unpaid on What.
4. Success: mark Gift received only after PaymentIntent `succeeded`. Then
   Document is allowed.
5. Cancel / fail / timeout / Stripe or Apple error: stay on What, gift unpaid,
   no letter, no crash. Discovery errors show the Stripe or Apple string.

## Terminal location

Tap to Pay needs a Stripe Terminal Location before reader discovery. The iOS
app never stores that id. Azure Function App `fieldforgepay` reads
`STRIPE_TERMINAL_LOCATION_ID`.

1. Stripe Dashboard → **Terminal** → **Locations** → Create location
   (https://dashboard.stripe.com/terminal/locations) — already done for test.
2. Set the id on Azure (never in the iOS app or git):

   ```bash
   az functionapp config appsettings set \
     --name fieldforgepay \
     --resource-group <rg> \
     --settings STRIPE_TERMINAL_LOCATION_ID=<paste from Dashboard>
   ```

3. Republish `azure-function/`.
4. Stop Xcode, disable **All Exceptions**, delete FieldForge from the iPhone.
5. Install this build and **launch from the icon** (no debugger). Collect,
   then hold a physical contactless card to the **top of the phone**.

`POST /api/connection-token` returns `{ secret, locationId }` and creates the
token with that location. **400** if the env var is missing. A tap-to-pay
PaymentIntent uses the same location. Pay-link routes do not.

If Azure has no location, Collect alerts:

> Create a Terminal location in Stripe Dashboard and set STRIPE_TERMINAL_LOCATION_ID on Azure.

and stays on What. `discoverReaders` is not called.

Tap to Pay, text pay link, and email pay link cannot go to Document until that
succeeded callback. Cash, check, in-kind, pledge, recorded card, and other may
proceed; a next action is still required at visit end.

## Request the entitlement

1. In the Apple Developer account for team `964M77TDXU`, request
   **Tap to Pay on iPhone**:
   [https://developer.apple.com/contact/request/tap-to-pay-on-iphone/](https://developer.apple.com/contact/request/tap-to-pay-on-iphone/)
2. Bundle ID: `org.rexautistikonlabs.fieldforge`
3. Merchant ID (already active): `merchant.org.rexautistikonlabs.fieldforge`
4. Payment partner: Stripe Terminal

A build that declares the key without the grant fails to sign. After the grant,
`FieldForge.entitlements` and `project.yml` already list:

```
com.apple.developer.proximity-reader.payment.acceptance = true
```

Then `xcodegen generate` and run on a physical iPhone XS or later.

Azure `fieldforgepay` needs `STRIPE_SECRET_KEY` (existing test key, already
used for pay links) so `POST /api/connection-token` can mint a Terminal
connection token, and `STRIPE_TERMINAL_LOCATION_ID` so that token is scoped to
the Dashboard location. Republish `azure-function/` after setting the env.

Downloading orgs never request this entitlement, never see a CSR, and never
see Azure. They tap **Connect Stripe** in Settings; FieldForge uses the
platform merchant ID.

## How collect is built

One straight line, all of it on the main actor, in the shape of Stripe's own
Tap to Pay sample:

```
dismiss keyboard
  -> POST /api/connection-token          (Azure; secret + locationId)
  -> empty locationId? alert, stop here  (discoverReaders is never called)
  -> Terminal.initWithTokenProvider(...) (provider owned for the process)
  -> Terminal.shared.delegate = ...
  -> already connected? skip to retrieve
  -> discoverReaders                     (once)
  -> connectReader                       (started from didUpdateDiscoveredReaders)
  -> retrievePaymentIntent
  -> processPaymentIntent                ("Hold card to top of iPhone")
```

Five rules hold that line together:

1. **The connection token provider is owned for the life of the process.**
   Stripe re-asks for a token during connect *and* during confirm. Creating the
   provider inline in the `initWithTokenProvider` call left nothing retaining
   it, so the second ask called into freed memory — mid-tap, right after the
   hold-card sheet came up.
2. **`Terminal.shared.delegate` is set once**, before anything asks Terminal to
   do work.
3. **`discoverReaders` runs at most once per connect**, and the reader is kept
   across collects. `connectReader` is started from inside
   `didUpdateDiscoveredReaders` rather than after returning from discovery,
   because a successful connect is what ends discovery — so there is no window
   in which a second discovery could start underneath the hold-card sheet.
4. **Nothing cancels a discovery that already produced a reader.** Cancel and
   timeout cancel the `Cancelable` only while discovery is still looking.
5. **Main-actor isolation instead of locks.** Terminal calls back on the main
   thread, one step of one collect is outstanding at a time, and exactly one
   place resumes each continuation. The `AsyncThrowingStream` relays, callback
   gates and `OSAllocatedUnfairLock` boxes this file used to carry are gone.

Sixty seconds with no card cancels the outstanding step and leaves the gift
unpaid on What. Cancel returns to What immediately and never waits on Stripe's
cancel completion.

## The app cannot cancel Apple's card-read screen

This is the limit, and it is worth stating plainly because three rounds of
fixes went past it.

Once `processPaymentIntent` starts the reader, **Apple's ProximityReader
presents the card-read screen itself**. It is a system UI drawn above every
app window, and an app is not permitted to layer over it — that restriction is
the point of the entitlement, because an app that could draw over the card
screen could impersonate it. FieldForge's hold-card overlay lives inside the
app's own window, so from the moment Apple's screen appears the app's Cancel
button is *behind* it and cannot be tapped. Nothing in the app can dismiss
that screen either; the only lever is `Cancelable.cancel`, which asks Stripe to
end the session — and a wedged session is exactly the case where that does not
answer.

So the app's Cancel is honest about its reach: it covers the connection token,
discovery, connect and retrieve, and the overlay says outright that Apple's
screen owns Cancel once it appears. Beyond that the staffer force-quits, and
the switch below is why that is survivable rather than a lost gift.

Cancel is the one path that must never depend on any of it. The button is a
plain `Button`, never disabled, and `PaymentCoordinator.cancelTapToPay()` is
**not `async`** — the compiler will not let an `await` into it. It clears the
in-flight lock, the launch lock and the overlay on the spot, cancels the collect
task, and only then hands Stripe a cancel on a background queue that nobody
waits for. If Cancel ever fails on a device again, switch Tap to Pay off in
Settings → Payments and keep taking cards by pay link.

**No Stripe Terminal call runs on the main thread.** They all go through
`TerminalQueue`, a serial background queue. This is not tidiness: tearing down a
live reader session blocks the calling thread, and `Cancelable.cancel` on the
main actor — on the very tap meant to escape — blocked the run loop, so the
overlay never re-rendered and force-quitting was the only way out.
`Scripts/check-duplicate-symbols.sh` fails the build check if a
`Cancelable.cancel` ever escapes that queue again.

One guard sits outside that line: **every Terminal entry point runs through an
Objective-C exception shim** (`catchingTerminalException`). Stripe Terminal
reports integration mistakes — a missing Info.plist key, a call it considers
illegal in its current state — by raising `NSException`, which Swift cannot
catch and which kills the process with SIGABRT. The shim turns that into an
alert on What carrying Stripe's own reason, and writes a fault to the log.
If Collect ever fails with an alert you don't recognise, read that line:
Console.app → the iPhone → search `Terminal raised during` (subsystem is the
app's bundle id, category `payments`). It names the exact call and Stripe's
reason.

## Device verification (no debugger)

Stripe Terminal and Apple Tap to Pay raise **NSException** internally while
presenting UI. Xcode's **All Exceptions** breakpoint stops on those even though
the SDK handles them itself, which looks exactly like a crash. Test from the
Home Screen icon.

On a registered iPhone:

1. Stop Xcode (Product → Stop).
2. Breakpoint navigator → delete or uncheck **All Exceptions** (and Swift Error
   if it is on).
3. Delete FieldForge from the iPhone.
4. Install this build, then **launch it from the app icon on the Home Screen** —
   not ⌘R, not attached to the debugger.
5. **Settings → Payments → Tap to Pay on iPhone → on.** Off is the shipped
   default; a fresh install will not have it.
6. Capture → gift → enter an amount → Tap to Pay → **Collect**.
7. Hold a **physical contactless card** flat against the **top** of the phone,
   above the camera bump, and keep it there until the sheet reports a result.
   In test mode use a Stripe Terminal test card. There is no simulated reader
   on this path.

Staff Wallet stays off. Text and email pay links stay.

### After device test

Confirm all of these on the physical iPhone:

- [ ] With the switch **off**, the Tap to Pay tile is disabled and captioned *Off*, and the gift can still be taken by pay link.
- [ ] Hold-card UI appears (`Hold card to top of iPhone`).
- [ ] No crash when a contactless card is presented at the top of the phone.
- [ ] Cancel during hold-card returns cleanly to What (no hang, no abort).
- [ ] Sixty seconds with no card times out, leaves the gift unpaid, and issues no letter.
- [ ] Second Collect in the same session still works (fresh discover if the reader dropped; not a stale reader).
- [ ] Failure alert shows if the card is pulled away or declined; the app does not abort.
- [ ] Force-quit during hold-card, then relaunch from the icon: Today paints, no white screen.

**If any of these fail, turn the switch back off.** The pay link is the primary
donor path and does not depend on any of this.

## What this pass does not include

QR codes. CloudKit at launch. Secret keys on iOS. Staff Apple Pay Wallet.
