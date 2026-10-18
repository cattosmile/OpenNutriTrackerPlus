# Fork dev environment (NixOS / Linux)

How this fork is set up and developed on Linux. Everything below was verified
working on NixOS 26.05 (kernel 6.18, Hyprland) on 2026-10-19. See also
`AGENTS.md` (canonical agent instructions for this repo) and `GettingStarted.md`
(upstream's Windows-oriented setup).

## Repository layout

- `origin` → `github.com/cattosmile/OpenNutriTrackerPlus` (this fork)
- `upstream` → `github.com/simonoppowa/OpenNutriTracker` (original)
- Pull upstream updates: `git fetch upstream && git merge upstream/main`

## Toolchain

Enter the environment before anything else:

```sh
nix-shell
```

This provides FVM, Flutter 3.44.6 (pinned in `.fvmrc`), JDK 17, the Android
SDK and `just`. Always invoke Flutter through `fvm flutter ...`.

One-time setup (already done on this machine, rerun only after `git clean`):

```sh
fvm install
cp .env.example .env        # placeholders are fine for debug builds
fvm flutter pub get
fvm dart run build_runner build
```

## Running the app

### Waydroid (primary — near-native speed, host GPU, physical keyboard)

Requires (already enabled in the NixOS config at `~/nix`):
`virtualisation.waydroid.enable` and `networking.nftables.enable` (the kernel
has no legacy iptables modules; nftables also makes waydroid use its nft
network backend).

After a host reboot:

```sh
waydroid session start      # keep running
waydroid show-full-ui       # opens the Android window
```

Then, inside `nix-shell` in this repo:

```sh
just dev_waydroid
```

ADB connects to `192.168.240.112:5555` (the `persist.service.adb.tcp.port`
property is set in the container, so this survives container restarts). The
develop-flavor package is
`com.opennutritracker.ont.opennutritracker.develop`.

### QEMU emulator (fallback)

```sh
just start_emulator   # AVD 'flutter_emulator', x86_64, KVM
just dev
```

Physical keyboard works (`hw.keyboard = yes` in the AVD config). AVDs live in
`~/.android/avd` (pinned via `ANDROID_AVD_HOME` in `shell.nix` — without that
pin, AVDs scatter across XDG dirs and `flutter emulators` finds nothing).

## Checks before committing

```sh
just ci        # = l10n guards + build_runner + format check + tests + analyze
```

Fast feedback loop: `fvm flutter analyze`, `fvm flutter test`.

Rules that matter for code changes (details in `AGENTS.md`):
new/changed strings go into `lib/l10n/intl_en.arb` only; other locales come
from Weblate. Regenerate (`fvm dart run build_runner build`) after editing
`@HiveType`/`@JsonSerializable` classes; the generated `*.g.dart` files are
committed except `lib/generated/` and `env.g.dart`.

## iOS

iOS builds are not possible on Linux (Xcode/macOS only). Plan: build via
GitHub Actions macOS runners once there are changes to ship. All feature
development happens against Android; iOS-specific code (Podfile, Runner
project) is rarely touched.

## Host NixOS notes

- The waydroid/NixOS changes live in `~/nix` (modules
  `nixos/virtualization/waydroid.nix`, `nixos/firewall.nix`).
- `~/nix` is a git repo; new files must be `git add`ed or nix flakes won't
  see them.
