# Building SimpleBooks installers

SimpleBooks ships as a desktop app packaged with [electron-builder](https://www.electron.build/).
This document covers producing installers on each platform, the pitfalls worth knowing about
in advance, and how to verify what you built.

> **Cross-platform builds do not really work.** electron-builder can *sometimes* produce a
> Windows installer from Linux, but code signing, native tooling and file permissions all
> differ per platform. Build each target on that platform (or in CI on the matching runner).
> This is the single most common source of wasted time.

---

## 1. Prerequisites (all platforms)

| Requirement | Notes |
| --- | --- |
| **Node.js 20 or newer** | Node 22 LTS is what this project is developed against. |
| **npm 10+** | Ships with Node 20+. |
| **~3 GB free disk** | Electron binaries, caches and output add up quickly. |
| **Network on first build** | electron-builder downloads the Electron runtime (~100 MB per platform/arch) and caches it in `~/.cache/electron` (Linux), `~/Library/Caches/electron` (macOS) or `%LOCALAPPDATA%\electron\Cache` (Windows). |

```bash
npm install          # also runs scripts/setup-ocr-assets.mjs
npm test             # 29 unit tests — do this before packaging
npm run build        # type-check + Vite build into dist/
```

`npm install` must succeed **before** packaging: its `postinstall` step copies the Tesseract
worker, the WASM core and the English language model into `public/ocr`, and Vite then copies
that into `dist/ocr`. Skip it and you get an app that cannot read receipts.

**Verify the OCR assets made it in** — cheap check, saves a broken release:

```bash
ls -la dist/ocr/worker.min.js dist/ocr/tessdata/eng.traineddata.gz
# eng.traineddata.gz should be ~10.9 MB
```

---

## 2. The commands

```bash
npm run electron:build        # installers for the current platform → release/
npm run electron:build:dir    # unpacked app directory only (fast, for smoke tests)
```

`electron:build` runs `npm run build` first, so you never package a stale `dist/`.

To target specific platforms or architectures, pass electron-builder's flags through:

```bash
npx electron-builder --mac                       # current arch
npx electron-builder --mac --arm64 --x64         # both Apple silicon and Intel
npx electron-builder --win --x64
npx electron-builder --linux
npx electron-builder --linux AppImage            # one target only
npx electron-builder --linux --dir               # unpacked, no installer
```

Remember to run `npm run build` yourself when calling `npx electron-builder` directly —
only the `npm run electron:build*` scripts do it for you.

### What each platform produces

Output lands in `release/`, named `SimpleBooks-<version>-<os>-<arch>.<ext>`.

| Platform | Targets | Artifacts |
| --- | --- | --- |
| **macOS** | `dmg`, `zip` | `SimpleBooks-1.0.0-mac-arm64.dmg`, `…-mac-x64.dmg`, plus `.zip` of each |
| **Windows** | `nsis`, `portable` | `SimpleBooks-1.0.0-win-x64.exe` (installer), `SimpleBooks-1.0.0-win-x64.exe` (portable, in `release/`) |
| **Linux** | `AppImage`, `deb` | `SimpleBooks-1.0.0-linux-x86_64.AppImage`, `simplebooks_1.0.0_amd64.deb` |

---

## 3. Windows

### Toolchain

- Windows 10/11, or a Windows CI runner.
- **No Visual Studio needed.** This app has zero native modules — everything in the renderer
  is bundled by Vite, and the main process uses only `electron` and Node builtins. If you add a
  native dependency later, you will need the Visual Studio Build Tools with the *Desktop
  development with C++* workload.

### Build

```powershell
npm install
npm run electron:build
# or: npx electron-builder --win --x64
```

### Targets, as configured

`nsis` produces a normal installer that:
- is **not** one-click (`oneClick: false`) — the user sees a real wizard
- installs **per user** (`perMachine: false`), so it never needs administrator rights
- lets the user change the install directory
- creates Desktop and Start Menu shortcuts named *SimpleBooks*

`portable` produces a single `.exe` that runs without installing. Useful for a locked-down
machine, but note the caveat under *Data location* below.

### Pitfalls

**Code signing.** An unsigned installer triggers *Windows protected your PC* (SmartScreen).
Users can click through via *More info → Run anyway*, which is fine for internal use and
awful for public distribution. To sign, set these before building:

```powershell
$env:CSC_LINK       = "C:\path\to\certificate.pfx"   # or a base64 string
$env:CSC_KEY_PASSWORD = "…"
```

An EV certificate on a hardware token cannot be used this way — it needs
`signtool` with the token plugged in, usually via electron-builder's `win.sign` hook.
Reputation with SmartScreen accrues over time and downloads even when signed; a brand-new
certificate will still warn at first.

**Path length.** Windows' 260-character `MAX_PATH` limit can break the build when the repo sits
deep in a user directory. Build from a short path such as `C:\src\simplebooks`, or enable long
paths (`Computer\HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1`).

**Antivirus.** Real-time scanning frequently locks files inside `release/` mid-build, producing
confusing `EBUSY`/`EPERM` errors. Exclude the project directory, or the `release/` folder at minimum.

**Data location.** IndexedDB lives in `%APPDATA%\SimpleBooks`. The *portable* build uses a
temporary directory by default, so **data does not persist between runs** unless you set
`PORTABLE_EXECUTABLE_DIR`. If your users want a genuinely portable app with persistent books,
prefer the installer, or set `portable.unpackDirName` and point `app.setPath('userData', …)` at
it. Whichever you choose, tell them where the data lives and remind them to use
*Settings → Export backup*.

---

## 4. macOS

### Toolchain

- macOS 12 or newer.
- **Xcode Command Line Tools** — `xcode-select --install`. Needed for `codesign` and `hdiutil`
  even when you are not signing with a real certificate.
- Apple silicon can build both `arm64` and `x64`; an Intel Mac cannot build `arm64`.

### Build

```bash
npm install
npm run electron:build
# both architectures explicitly:
npx electron-builder --mac --arm64 --x64
```

### Pitfalls

**Signing and notarization are effectively mandatory.** Since macOS 10.15, an unsigned or
un-notarized app downloaded from the internet is blocked outright — the user sees
*"SimpleBooks" is damaged and can't be opened*, which is a lie the OS tells about quarantined
apps. Locally built apps run fine (no quarantine attribute), so you will not notice this until
someone else downloads your `.dmg`.

To sign and notarize you need a paid Apple Developer account and a *Developer ID Application*
certificate in your login keychain:

```bash
export APPLE_ID="you@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="abcd-efgh-ijkl-mnop"   # appleid.apple.com → App-Specific Passwords
export APPLE_TEAM_ID="XXXXXXXXXX"
npx electron-builder --mac
```

electron-builder notarizes automatically when those variables are present and a valid
Developer ID certificate is found. Notarization is a round trip to Apple and typically adds
2–15 minutes.

To skip signing deliberately (local testing, CI smoke build):

```bash
export CSC_IDENTITY_AUTO_DISCOVERY=false
npx electron-builder --mac
```

**Hardened runtime.** `mac.hardenedRuntime: true` is set in `electron-builder.yml`, which
notarization requires. SimpleBooks needs no special entitlements — it opens no camera, no
microphone, and makes no network requests. If you ever add a native module, you will likely
need `com.apple.security.cs.allow-unsigned-executable-memory` in an entitlements plist.

**A user who already has a quarantined copy** can clear it locally:

```bash
xattr -dr com.apple.quarantine /Applications/SimpleBooks.app
```

Useful for debugging. Do not ship it as installation instructions.

**Universal binaries.** `--universal` exists but doubles app size and has historically been
flaky with asar. Two separate `arm64`/`x64` DMGs are the safer choice, which is what
`electron-builder.yml` configures.

**Data location.** `~/Library/Application Support/SimpleBooks`.

---

## 5. Linux

### Toolchain

- Any reasonably current distribution.
- `AppImage` needs no extra tooling — electron-builder downloads what it needs.
- `deb` needs **`fpm`**, which electron-builder fetches automatically on first use. On a minimal
  container you may also need:

  ```bash
  sudo apt-get install -y fakeroot dpkg rpm binutils
  ```

- Building a `.deb` on a non-Debian distribution works, but you cannot install it there to test.

### Build

```bash
npm install
npm run electron:build
# single target:
npx electron-builder --linux AppImage
```

### Pitfalls

**`maintainer` is required for `.deb`.** Without it the build fails with
*"It is required to set Linux .deb package maintainer"*. It is set in `electron-builder.yml`
(`linux.maintainer`) and in `package.json` (`author`) — **both are placeholders
(`maintainer@simplebooks.invalid`) and must be changed before you distribute anything.**

**AppImage and the sandbox.** On some kernels and container images an AppImage fails with a
`chrome-sandbox` permission error. Either run with `--no-sandbox` (weakens the renderer
sandbox — do not do this casually), or ensure unprivileged user namespaces are enabled:

```bash
sudo sysctl -w kernel.unprivileged_userns_clone=1
```

**Missing runtime libraries.** A slim distribution may lack the shared libraries Chromium
expects (`libgtk-3`, `libnss3`, `libasound2`, `libgbm1`, …). The app exits immediately with a
linker error; `ldd release/linux-unpacked/simplebooks | grep 'not found'` tells you which.

**Data location.** `~/.config/SimpleBooks`.

---

## 6. Pitfalls that bite on every platform

### Icons

electron-builder derives every platform icon from **`build/icon.png`** — a single 1024×1024
PNG generated from `build/icon.svg`. If you change the artwork, regenerate the PNG at exactly
1024×1024; anything smaller makes electron-builder complain, and a non-square source is
silently distorted. Both files are committed, so a clean clone builds with correct icons.

### `files`, and why `node_modules` is excluded

`electron-builder.yml` contains:

```yaml
files:
  - dist/**/*
  - electron/**/*
  - package.json
  - '!node_modules/**/*'
```

That last line matters more than it looks. electron-builder bundles production dependencies by
default, but SimpleBooks needs none at runtime: Vite bundles every renderer dependency into
`dist/`, and the main process imports only `electron` and Node builtins. Including
`node_modules` made `app.asar` **192 MB**; excluding it makes it **32 MB**.

So: **if you add a dependency that the main process `require`s at runtime**, this exclusion
will break it. Either drop the exclusion, or add a narrow re-inclusion after it:

```yaml
files:
  - '!node_modules/**/*'
  - 'node_modules/some-native-module/**/*'
```

### Architecture mismatches

- Electron is downloaded per platform *and* per architecture. `--arm64 --x64` means two
  downloads and two output artifacts.
- On Apple silicon, forgetting `--x64` yields an arm64-only DMG that Intel Macs cannot run.
- Node's own architecture is irrelevant to the packaged output, but a Rosetta-emulated
  terminal on macOS can silently pick `x64` — check with `node -p process.arch`.

### Version numbers

`package.json` `version` becomes the artifact filename, the installer version, and the *About*
dialog. Bump it before every release; Windows in particular refuses to "upgrade" to the same
version.

### Stale `dist/`

`npx electron-builder` does **not** rebuild the renderer. If you package straight after editing
source, you ship the previous build. Use `npm run electron:build`, or run `npm run build` first.

### `release/` is gitignored

Artifacts are never committed. Publishing is explicitly disabled (`publish: null`) because
SimpleBooks has no update server — it is an offline app.

---

## 7. Testing what you built

### Quick smoke test — unpacked

Fastest loop, no installer involved:

```bash
npm run electron:build:dir
# Linux:
./release/linux-unpacked/simplebooks
# macOS:
open ./release/mac-arm64/SimpleBooks.app
# Windows:
.\release\win-unpacked\SimpleBooks.exe
```

### Automated check over the DevTools protocol

You can drive the packaged binary exactly like a browser, which is how this build was verified:

```bash
./release/linux-unpacked/simplebooks --remote-debugging-port=9222
```

then from another terminal, with Playwright installed:

```js
import { chromium } from 'playwright'
const browser = await chromium.connectOverCDP('http://127.0.0.1:9222')
const page = browser.contexts()[0].pages()[0]
console.log(await page.title())                                  // → SimpleBooks
console.log(await page.evaluate('!!window.simplebooks?.isDesktop')) // → true
```

### The checklist that actually matters

Run through this against the **installed** app, not the dev server. These are the things that
only break once packaged:

1. **It launches, and the window is not blank.** A blank window almost always means `dist/`
   was not included or `base: './'` was lost from `vite.config.ts`.
2. **The dashboard shows the two sample companies.** Proves the renderer booted and IndexedDB
   is writable in the packaged app's data directory.
3. **OCR reads a receipt.** *Expenses → Import scan*, drop in a photo. This exercises the
   Tesseract worker, the WASM core and the 11 MB language model — all loaded from inside
   `app.asar`. It is the most package-sensitive feature in the app.
4. **OCR made no network requests.** Confirm with DevTools' Network tab, or unplug the machine
   first. This is the offline-first guarantee.
5. **Save as PDF** writes a real file through the native dialog.
6. **Print** shows only the document sheet, not the app chrome.
7. **Export backup (JSON)** and **Restore** round-trip.
8. **The application menu works** — File → New Invoice, New Receipt, Import Scan, Backup.
9. **Data survives a restart.** Quit fully and reopen; your invoices should still be there.
10. **No console errors** in DevTools (View → Toggle Developer Tools).

### What was verified in this repository

For transparency about what has and has not been exercised:

**Verified on Linux (x64):**

- `npx electron-builder --linux` completes and produces both artifacts:
  `SimpleBooks-1.0.0-linux-x86_64.AppImage` (128 MB) and
  `SimpleBooks-1.0.0-linux-amd64.deb` (91 MB)
- The unpacked app and the AppImage both launch, load the renderer from `app.asar`, seed the
  sample companies, expose the preload bridge, and resolve the bundled Inter font
- OCR extracted `Harbor & Finch Coffee / 2026-03-14 / 40.80 / 3.30 / Meals & Entertainment`
  from a test receipt **from inside `app.asar`, with zero network requests**
- Zero console errors, zero CSP violations
- `.deb` metadata is well-formed (`dpkg-deb -I`)

**Not verified:** macOS and Windows installers, and signing or notarization on any platform.
Those need the respective operating systems and certificates. Their configuration is written
but unproven — treat the first build on each as one you must test end to end using the
checklist above.

---

## 8. The production Content-Security-Policy

`vite.config.ts` injects a CSP `<meta>` tag into `dist/index.html` **for production builds
only**:

```
default-src 'self' file:;
script-src 'self' file: blob: 'wasm-unsafe-eval';
worker-src 'self' file: blob:;
style-src 'self' file: 'unsafe-inline';
img-src 'self' file: data: blob:;
font-src 'self' file: data:;
connect-src 'self' file: data: blob: https://tessdata.projectnaptha.com;
object-src 'none';
base-uri 'self';
form-action 'none';
```

### Why it exists

A packaged Electron app is a browser with the user's filesystem behind it. Without a CSP,
anything that manages to inject script into the renderer runs with the renderer's privileges.
SimpleBooks reduces the blast radius three ways: `contextIsolation` is on, `nodeIntegration`
is off, and the preload script exposes exactly one narrow surface (`saveFile` and menu
subscriptions). The CSP is the third layer — it stops injected markup from loading remote code
at all. Electron warns loudly in the console when a renderer has no CSP, and that warning is
worth listening to.

### Why each unusual directive is there

| Directive | Reason |
| --- | --- |
| `'wasm-unsafe-eval'` | Tesseract's OCR engine is WebAssembly. Without this, compiling the WASM module is blocked and OCR fails. It permits WASM compilation only — **not** `eval` of JavaScript. |
| `blob:` in `script-src` / `worker-src` | Tesseract.js and pdf.js both run in Web Workers created from blob URLs. |
| `'unsafe-inline'` in `style-src` | The printed document sheet is laid out with inline `style` attributes so it renders identically in the app, in print and in the generated PDF. Inline **styles** cannot execute code; this is not the same risk as inline scripts. |
| `data:` in `img-src` | Company logos and scanned receipt images are stored as data URLs, so JSON backups stay self-contained. |
| `file:` throughout | The packaged app is served from `file://` inside `app.asar`. |
| `https://tessdata.projectnaptha.com` in `connect-src` | The **only** remote host, and only a fallback: if the language model is somehow missing from the package, Tesseract.js downloads it once and caches it. A correctly built package never contacts it. |
| `object-src 'none'` | No plugins, ever. |
| `form-action 'none'` | Nothing in this app submits a form anywhere. |

### It is deliberately absent in development

Vite's dev server needs an inline bootstrap script and a websocket for hot reload, both of
which a policy strict enough to be worth having would block. The plugin that injects the tag is
declared `apply: 'build'`, so `npm run dev` and `npm run electron:dev` run without it — which
is exactly why **you must smoke-test the packaged build**. A CSP violation is invisible until
you do.

### If you change the CSP

Verify it against the packaged app, not the dev server, and check the DevTools console for
`Refused to …` messages. The features most likely to break are, in order: OCR (WASM and
workers), PDF export (`html2pdf` uses canvas and workers), and the printed sheet (inline
styles).
