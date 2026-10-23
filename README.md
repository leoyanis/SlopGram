# SlopGram

Instagram with the slot machine turned against you. Built on [SCInsta](https://github.com/SoCuul/SCInsta) (GPLv3) with every setting removed.

Stories, posting and messages are untouched. Only scrolling Reels and the home feed costs you. There are no settings, on purpose: there's nothing to switch off when the urge hits.

## The rules

- **Cold start.** The first time you open Reels after starting Instagram, you wait 30 seconds. Every other start in the past hour adds 15 seconds, up to 2 minutes. Leave the screen and the clock starts over.
- **Free runs.** Each reel, and each screen of the home feed, uses up one unit of a short free run.
- **Roulette.** When the run is empty, a wheel decides if you get another one. The coral slice is your chance.
- **Lock.** Lose the spin, or hit a random freeze, and Reels and the feed stay locked until you restart Instagram, which brings back the cold start.

The schedule is front-loaded: it stops you fast, lets you go a while, stops you fast again, then gets very hard.

| After this many wins | Free run | Freeze chance per reel | Chance to win the spin |
|---|---|---|---|
| 0 | 1–5 | 6% | 40% |
| 1 | 10–20 | 1.5% | 30% |
| 2 | 2–5 | 5% | 20% |
| 3+ | 1–3 | 10% | 10% |

Between midnight and 6 am the spin pays half as often.

In a simulation of 200,000 app starts where you keep scrolling and always spin, a start gives you 7.5 reels on average (median 4). Getting 30 or more happens in 0.08% of starts.

Reels opened from messages follow the same rules and show a "Not now" button that takes you back to the chat.

While a SlopGram screen is up, the video behind it is paused and muted.

## Installing

You need an iPhone, a computer, and a **decrypted** Instagram IPA. This repo doesn't ship Instagram itself; you have to get or decrypt that yourself. SlopGram is tested against Instagram 452.

**Easiest: inject the prebuilt tweak.** Download `SlopGram.dylib` from [Releases](../../releases) and inject it into your Instagram IPA with a sideloading tool that supports tweaks, such as [Sideloadly](https://sideloadly.io) ("Advanced options", then inject dylibs), [Feather](https://github.com/khcrysalis/Feather) or [cyan](https://github.com/asdfzxcvbn/pyzule-rw). Then install the result as usual. A free Apple ID works but needs re-signing every 7 days; a paid developer account lasts a year.

**From source** (macOS, [Theos](https://theos.dev), `cyan`, `ipapatch`):

```sh
cp signing.env.example signing.env   # fill in your team, certificate and profile
./package.sh            # -> packages/SlopGram.ipa
./package.sh --install  # and install on the paired iPhone
```

**Jailbroken:** `make package FINALPACKAGE=1` gives a .deb.

### Things to know

- It installs next to the App Store Instagram. Delete that one, or you'll just drift back to it.
- Re-signed Instagram normally logs you out on every restart and nags you to "update on TestFlight". SlopGram fixes both (`src/SlopGram/SGSideload.xm`).
- Push notifications don't work in a re-signed Instagram. Messages still arrive; you just don't get alerts.
- Using a modified Instagram is against Instagram's terms. Your account could be restricted. Use it at your own risk.

## Layout

- `src/SlopGram/`: SlopGram itself
  - `SGEngine`: the odds and the state, with no UI
  - `SGGate`: watches the scrolling, counts reels and puts up the screens
  - `SGOverlayView`: the screens (cold start ring, wheel, lock, freeze)
  - `SGHooks.xm`: the only file that touches Instagram's classes
  - `SGSideload.xm`: fixes for running re-signed (login keychain, app groups, TestFlight nag)
- `src/Features/`: the SCInsta features that are kept, with fixed options
- `harness/`: SlopLab, a stand-in app for the simulator that runs the same code
- `tests/EngineTests.m`: rule tests and the odds simulation

## Testing

```sh
# Odds and rules (macOS)
clang -fobjc-arc -framework Foundation -Isrc/SlopGram src/SlopGram/SGEngine.m tests/EngineTests.m -o /tmp/engine_tests && /tmp/engine_tests

# Simulator: build SlopLab, install, run every scenario
harness/build.sh && xcrun simctl install <udid> harness/build/SlopLab.app
harness/run_all.sh <udid> /tmp/sloplab
```

## License

GPLv3, like SCInsta, which this is a modified version of. SlopGram's own code is in `src/SlopGram/`, `harness/` and `tests/`.
