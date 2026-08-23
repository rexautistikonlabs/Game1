# Tap to Pay on iPhone

FieldForge can take a contactless card on this iPhone via **Stripe Terminal**.
Selecting the Tap to Pay tile is not a charge. **Collect** (or Next on What)
starts Terminal collect.

That path is gated on two things, both of which must be true at runtime:

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

## Device verification (no debugger)

`discoverReaders` previously aborted with SIGABRT / `pthread_kill` when it ran
on the main thread with the amount keyboard still up, then finished twice
(reader from the delegate, then Stripe’s nil completion). Stripe Terminal and
Apple Tap to Pay also raise **NSException** internally while presenting UI.
Xcode’s **All Exceptions** breakpoint treats those as crashes even when
FieldForge catches them with `FFCatchException`.

On a registered iPhone:

1. Stop Xcode (Product → Stop).
2. Breakpoint navigator → disable **All Exceptions** (and Swift Error if on).
3. Delete FieldForge from the iPhone.
4. Install this build, then **launch from the icon** — not Run from Xcode.
5. Capture → gift → Tap to Pay → **Collect**.
6. Hold a physical contactless card to the **top** of the phone.

Staff Wallet stays off. Text and email pay links stay.

## What this pass does not include

QR codes. CloudKit at launch. Secret keys on iOS. Staff Apple Pay Wallet.
