# BG3iOS

**Baldur's Gate 3 on iPhone — the native Mac version, adapted for iOS.**

[Русская версия](README.ru.md)

BG3iOS downloads the official macOS (Apple Silicon) version of Baldur's Gate 3 from Steam with your own account and
adapts it for iOS right on your iPhone. The game runs natively, with no emulation and no streaming. BG3iOS doesn't
contain or distribute any game files: you can play only if your Steam account owns the game.

> [!IMPORTANT]
> **You may use BG3iOS only if you own Baldur's Gate 3 on Steam.** See the [disclaimer](#disclaimer).

<!-- Screenshots: coming soon -->

## Features

- **Downloads the game from Steam** with your account after checking that you own it. The download is 156 GB. If it
  stops, it resumes from where it left off.
- **Adapts the Mac version for iPhone** on the device. Nothing is installed from anywhere but Steam.
- **Choose the game language**: 15 languages for in-game text. The iPhone's language is used by default. Voices are in
  English, as in every version of the game.
- **Built-in touch gamepad that doesn't cover the game**:
  - The buttons sit in the black bars on both sides of the picture.
  - The sticks appear wherever you put your finger (left half: left stick, right half: right stick) and disappear when
    you lift it. A quick double tap clicks the stick (L3/R3).
  - A short tap in the top third of the picture acts as a mouse click.
- **Or play with a game controller**: choose **Controls → Game Controller** under the Play buttons and pair a DualSense,
  DualShock 4 or Xbox controller in Settings › Bluetooth (DualSense: hold PS and Create until the light bar blinks).
  The on-screen buttons are hidden while it's connected and come back if it disconnects.
- **Show or hide the FPS counter**: start with **Play with FPS Counter**, or hold three fingers on the screen for about
  a second during play.
- **Steam Cloud saves**: saves sync when BG3iOS opens and before you play, so you can continue on your PC or Mac. Copies
  that a sync replaces are kept for 30 days in Files › BG3iOS › Steam Cloud Backups.
- **Graphics tuned for iPhone** are applied on first launch. You can change them in the game's Options; **Reset Graphics
  to Optimal** brings them back.
- **A steady 30 FPS without stutters**: the game's own FPS limit is set to 30 (Options › Graphics). Above that, iOS
  slows the processor down right when the game loads a new area, and frames stall for up to 150 ms; at 30 FPS every frame
  stays on screen the same 33 ms. You can change the limit in the game, up to the display's 120 Hz.

## Requirements

| | |
|---|---|
| iPhone | **Tested on iPhone 17 Pro Max** (iOS 27). It may also work on iPhone 17 Pro. Earlier models haven't been tested. Minimum: **8 GB of RAM**. |
| iOS | 26 or later |
| Free space | **About 165 GB**: the game (156 GB) plus a 5% reserve |
| Steam | An account that owns **Baldur's Gate 3** (the Mac version comes with the Steam purchase) |
| Computer | A Mac for AltServer (tested: macOS 27, AltServer 1.8.2). AltServer also exists for Windows, but we haven't tested it. |
| Apple ID | A free Apple ID is enough |
| Internet | Wi-Fi for the 156 GB download |

## Installation

It takes about 15 minutes, plus the time to download the game. You only need the computer to install and refresh apps;
you play on the iPhone alone.

### Step 1. Install AltServer on your computer

AltServer is the companion app of [AltStore](https://altstore.io), which installs apps on your iPhone with your Apple ID.

**Mac**
1. Go to [altstore.io](https://altstore.io), find **AltStore Classic**, and download **AltServer for macOS**.
2. Open the downloaded `.zip` and drag **AltServer** to **Applications**.
3. Open AltServer. A diamond-shaped icon appears in the menu bar at the top of the screen. AltServer has no window; you
   work with it through this icon.

**Windows** (not tested by us)
1. Install **iTunes** and **iCloud** from Apple's website, not from the Microsoft Store.
2. Download **AltServer for Windows** from [altstore.io](https://altstore.io), install it, and start it. Its icon appears
   in the notification area of the taskbar.

### Step 2. Install AltStore on your iPhone

1. Connect your iPhone to the computer with a cable and unlock it. If the iPhone asks **Trust This Computer?**, tap
   **Trust** and enter your passcode.
2. **Mac:** open Finder, select your iPhone in the sidebar, and on the **General** tab turn on **Show this iPhone when on
   Wi-Fi**, then click **Apply**. This lets AltStore refresh apps over Wi-Fi later.
   **Windows:** do the same in iTunes (**Sync with this iPhone over Wi-Fi**).
3. Click the AltServer icon → **Install AltStore** → your iPhone.
4. Enter your Apple ID and password. They go only to Apple, which issues the certificate that signs your apps. If Apple
   asks for a verification code, enter it.
5. Wait for the message that AltStore has been installed.
6. On the iPhone, allow apps signed with your Apple ID: **Settings → General → VPN & Device Management** → your Apple ID
   → **Trust**.
7. Turn on Developer Mode: **Settings → Privacy & Security → Developer Mode** → on → **Restart**. After the restart,
   tap **Turn On** and enter your passcode. (iOS shows this option only after a sideloaded app is installed.)
8. Open **AltStore → Settings** and sign in with the same Apple ID. Keep AltServer running on the computer, with the
   iPhone on the same Wi-Fi network.

> [!NOTE]
> If signing in to AltStore fails with **HTTP 503**, a known AltStore bug since October 2026, install
> [our fixed AltStore](#fixed-altstore-sign-in-error-http-503) and sign in again.

### Step 3. Install BG3iOS

1. On the iPhone, open this page in Safari and download
   [**BG3iOS.ipa**](https://github.com/PavelDemyanov/BG3iOS/releases/latest/download/BG3iOS.ipa). It is saved to
   Files › Downloads.
2. Open **AltStore → My Apps**, tap **+** at the top left, and choose **BG3iOS.ipa**. Keep AltServer running and wait
   for the installation to finish.

Another way, from a Mac: download BG3iOS.ipa on the computer, hold **Option**, click the AltServer icon →
**Sideload .ipa…** → your iPhone → BG3iOS.ipa. On Windows, hold **Shift** instead of Option.

### Step 4. First launch

1. Open **BG3iOS**, read the disclaimer, turn on **I own Baldur's Gate 3 on Steam…**, and tap **Agree and Continue**.
2. **Get the signing certificate.** BG3iOS signs the game with the same certificate that AltStore used to install it.
   - Open AltStore first (you must be signed in), then switch back to BG3iOS without closing AltStore.
   - Tap **Signing Certificate → Get from AltStore**.
   - AltStore opens and asks you to create a password for the certificate. Enter any password and tap **Export**.
     You're returned to BG3iOS.
3. Tap **Sign In to Steam** and sign in with the account that owns Baldur's Gate 3. Approve the sign-in in the Steam
   app or enter the Steam Guard code.
4. When BG3iOS has checked your library, tap **Download from Steam (156 GB)**.
   - Keep BG3iOS open: iOS pauses apps in the background. The screen stays on while it downloads.
   - Plug in the charger and stay on Wi-Fi.
   - If the download stops, tap **Resume Download**. It continues from where it stopped.
5. Tap **Prepare for iPhone**.
6. If you want, pick another language under **Game Language**.
7. Tap **Play**.

## Every 7 days (free Apple ID)

Apple lets apps signed with a free Apple ID run for 7 days. AltStore renews them:

- Open **AltStore → My Apps → Refresh All** while AltServer is running on the computer and the iPhone is on the same
  Wi-Fi. AltStore also tries to refresh in the background.
- If an app expires, it won't open until you refresh it. Your game and saves stay on the iPhone.
- If AltStore gets a new certificate (for example, after you sign in again), get it again in BG3iOS: **Signing
  Certificate → Get from AltStore**. BG3iOS re-signs the game by itself.

## Fixed AltStore (sign-in error HTTP 503)

Since October 2026, signing in to AltStore 2.3.1 on iPhone often fails with **HTTP 503**
([altstoreio/AltStore#1842](https://github.com/altstoreio/AltStore/issues/1842)). Without signing in, AltStore can't
give BG3iOS its certificate. We made a fixed build of the same version:

- AltStore sends Apple an outdated program signature (User-Agent), which Apple now rejects.
- [#1851](https://github.com/altstoreio/AltStore/pull/1851) fixes this for Remote AltServer. Our build also fixes
  sign-in through AltServer on your computer, the usual case.
- **Tested:** AltServer 1.8.2 on macOS 27 with iPhone 17 Pro Max, sign-in works. The fix also covers Windows and older
  macOS, but we haven't tested them.

**How to install**
1. Download
   [**AltStore-2.3.1-signin-fix.ipa**](https://github.com/PavelDemyanov/BG3iOS/releases/latest/download/AltStore-2.3.1-signin-fix.ipa)
   on your computer.
2. Connect the iPhone. Hold **Option** (Mac) or **Shift** (Windows) and click the AltServer icon → **Sideload .ipa…** →
   your iPhone → choose the downloaded file.
3. Enter your Apple ID. The fixed AltStore replaces the old one; you don't need to delete anything first.
4. Open **AltStore → Settings** and sign in.

This build is unofficial and not made or supported by the AltStore team. Source code:
[PavelDemyanov/AltStore, branch `signin-fix-2.3.1`](https://github.com/PavelDemyanov/AltStore/tree/signin-fix-2.3.1)
(AGPL-3.0, like AltStore). It is still version 2.3.1, so once an official AltStore release fixes sign-in, install it the
usual way: AltServer → **Install AltStore**.

## Good to know

- **Performance** depends on the scene. Crowded areas, such as the city in Act 3, are the heaviest. Over long sessions
  the iPhone gets warm and slows down, so play in a cool place and without a thick case.
- **Memory:** close other apps before you play.
- **Privacy:** your Steam password goes only to Steam, encrypted, and is never stored. BG3iOS keeps a Steam session token
  in the iPhone's keychain. Your Apple ID goes only to Apple, through AltServer and AltStore. BG3iOS has no servers of its
  own and collects nothing.
- **Not supported yet:** updating the game after a new Steam patch. Multiplayer hasn't been tested.
- BG3iOS can also get a certificate from SideStore, but we haven't tested that.

## Troubleshooting

| Problem | What to do |
|---|---|
| AltStore sign-in: **HTTP 503** | Install [our fixed AltStore](#fixed-altstore-sign-in-error-http-503). |
| **Untrusted Developer** when opening an app | Settings → General → VPN & Device Management → your Apple ID → Trust. |
| An app doesn't open, or **Developer Mode** is mentioned | Settings → Privacy & Security → Developer Mode → on, then restart. |
| **AltStore didn't open. Is it installed?** in BG3iOS | Install AltStore and sign in to it, then try again. |
| BG3iOS doesn't get the certificate | Open AltStore, make sure you're signed in, switch back to BG3iOS without closing AltStore, and tap **Get from AltStore** again. |
| An app stopped opening after a week | Refresh it in AltStore (see [Every 7 days](#every-7-days-free-apple-id)). |
| **Not enough space** | The game needs about 165 GB free. Free up space and tap Download again. |
| The download stopped | Tap **Resume Download**. Keep BG3iOS on screen while it downloads. |
| **Baldur's Gate 3 is not in this Steam library** | Sign in with the Steam account that bought the game. |

Found a bug? [Open an issue](https://github.com/PavelDemyanov/BG3iOS/issues) and say which iPhone and iOS version you
use.

## Disclaimer

BG3iOS is an independent, unofficial compatibility tool. It is not affiliated with, endorsed by or sponsored by Larian
Studios, Valve Corporation or Apple Inc. Baldur's Gate 3 and all related trademarks belong to their respective owners.

**You may use BG3iOS only with a game you legally own.** Baldur's Gate 3 can be launched only after you sign in to your
own Steam account that holds a valid license for the game and download the game from Steam through this app.

**Any illegal use is strictly prohibited**, including piracy, sharing or distributing game files and circumventing copy
protection. The author does not condone or encourage unlawful use of the game or infringement of its developers'
copyrights.

The software is provided "as is", without warranty of any kind. The author accepts no liability for any damage, data
loss, account restrictions or other consequences arising from its use. You use it entirely at your own risk.

AltStore is a project of its own authors. The fixed AltStore build offered here is unofficial and not supported by them.

## Building from source

You need a Mac with Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
sh tools/make_ipa.sh   # → build/BG3iOS.ipa
```

The public build is signed ad hoc only so that the IPA carries the app's entitlements (the increased memory limit).
AltStore re-signs it with your certificate.

Layout:
- `lab/`: the app (SwiftUI, project generated by XcodeGen from `project.yml`).
- `kit/`: preparing a Mac app for iOS and signing Mach-O files on the device.
- `shims/`: stand-ins for the macOS frameworks that iOS doesn't have.
- `vendor/playport/`: the Steam client and content downloader from [Playport](https://github.com/playportdev/playport)
  (see `vendor/playport/NOTICE.md`).

## License

BG3iOS is licensed under the [GNU General Public License v3.0](LICENSE). The code in `vendor/playport` is GPL-3.0-or-later
with an additional permission (`vendor/playport/LICENSE-EXCEPTION.md`). The fixed AltStore is AGPL-3.0, with source in
[PavelDemyanov/AltStore](https://github.com/PavelDemyanov/AltStore/tree/signin-fix-2.3.1).

## Thanks

- [Playport](https://github.com/playportdev/playport): the Steam client and downloader.
- [AltStore](https://github.com/altstoreio/AltStore) by Riley Testut and contributors, and Igor Szalay for the fix in
  [#1851](https://github.com/altstoreio/AltStore/pull/1851).
- Larian Studios for Baldur's Gate 3.
