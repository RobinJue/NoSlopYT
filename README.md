# No Slop

A personal YouTube client for iPhone and iPad that feels like the real app, with none of the slop: no ads, no
Shorts, no sponsor reads, no clickbait, no algorithmic rabbit holes. Background playback, Picture in Picture and
downloads for offline viewing come free. It is installed from Xcode, not from the App Store, and has no server
component: everything runs on the phone.

> Work in progress. This README is a skeleton; the final version (setup of Google sign-in, how it works,
> troubleshooting) is written when the parts are integrated.

Design: [`docs/superpowers/specs/2026-11-03-noslop-design.md`](docs/superpowers/specs/2026-11-03-noslop-design.md)
· Plan: [`docs/superpowers/plans/2026-11-03-noslop-app.md`](docs/superpowers/plans/2026-11-03-noslop-app.md)

## Requirements

- macOS with Xcode 26.2 or newer (Swift 6.2). The app targets iOS 18.0 and later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer: `brew install xcodegen`.
- No third-party packages: Apple frameworks only.

## Build and run

```sh
./scripts/bootstrap.sh        # generates NoSlop.xcodeproj from project.yml
open NoSlop.xcodeproj         # then run the "NoSlop" scheme on a simulator
```

To run on your own iPhone, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (it is git-ignored) and
set `DEVELOPMENT_TEAM` to your Apple Developer Team ID.

From the command line, without code signing, for the simulator:

```sh
./scripts/build.sh
```

The Xcode project uses synced folders: adding or removing files under `NoSlop/` needs no regeneration. Run
`./scripts/bootstrap.sh` again only after changing `project.yml`.

### Mock services

Launch with the argument `-mockServices YES` (in Xcode: Product > Scheme > Edit Scheme > Run > Arguments, tick
`-mockServices YES`) to run on canned sample data instead of YouTube, with a throw-away library and settings that
never touch your real ones. Deep links work in both modes, for example on a simulator:

```sh
xcrun simctl openurl booted 'noslop://watch?v=dQw4w9WgXcQ'
xcrun simctl openurl booted 'noslop://route/settings'
```

Supported links: `noslop://watch?v=<id>[&t=<seconds>]`, `noslop://channel/<id>`, `noslop://playlist/<id>`,
`noslop://search?q=<text>`, `noslop://tab/<home|subscriptions|library|search>` and
`noslop://route/<settings|downloads|history|watchLater>`. Regular YouTube links are understood too.

## Tests

The logic lives in the local Swift package `NoSlopKit` and is tested on macOS, without a simulator:

```sh
./scripts/test.sh                       # swift test --package-path NoSlopKit
./scripts/test.sh --filter ContentFilter
NOSLOP_LIVE=1 ./scripts/test.sh --filter Live   # opt-in tests against the real YouTube
```

## Layout

| Path | What |
|---|---|
| `NoSlopKit/` | Swift package: InnerTube client and parsers, Google OAuth and Data API, feeds, library, downloads, SponsorBlock, DeArrow, mocks |
| `NoSlop/App/` | App entry point, `AppEnvironment` (composition root), `Router`, `RootView` |
| `NoSlop/DesignSystem/` | Shared views: thumbnails, video cards and rows, subscribe button, empty/error states |
| `NoSlop/Features/` | The screens: Home, Subscriptions, Search, Channel, Playlist, Watch, Library, Downloads, Settings, Account |
| `NoSlop/Player/` | The AVPlayer-based player and its overlay |
| `project.yml`, `Config/` | XcodeGen spec and build configuration |
| `scripts/` | `bootstrap.sh`, `build.sh`, `test.sh` |

## Credits and disclaimer

SponsorBlock and DeArrow are by Ajay Ramachandran (CC BY-NC-SA). No Slop is not affiliated with YouTube or Google.
