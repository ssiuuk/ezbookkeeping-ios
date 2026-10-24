# Working on this repository

This is the iOS app (SwiftUI) for Sam's ezBookkeeping server, which lives in a separate repository:
**https://github.com/ssiuuk/ezbookkeeping** (a fork of mayswind/ezbookkeeping with family books,
projects, merchants and other additions). The app shares no code with the server; it only calls the
server's HTTP API (`/api/v1/...`), the same one the web app and the Android app
(**https://github.com/ssiuuk/ezbookkeeping-android**) use. When in doubt about a request or a screen,
do what the Android app does: this app mirrors its features and requests.

## Layout

- `project.yml`: the XcodeGen spec. `EzBookkeeping.xcodeproj` and `EzBookkeeping/Info.plist` are generated
  by `xcodegen generate` and are not committed. iOS 17, Swift 5.9, no third-party dependencies.
- `EzBookkeeping/App`: the app entry point and `AppState` (servers, active server, books, data version).
- `EzBookkeeping/API`: `APIClient` (headers, the `{"success", "result"}` envelope, 401 handling) and `APIError`.
- `EzBookkeeping/Models`: lenient JSON reading (`JSONObject`) and the server's models, read like the
  Android app's `data/Models.java`.
- `EzBookkeeping/Support`: formatting, remembered choices, Keychain, colors.
- `EzBookkeeping/Views`: the screens; `TransactionEditModel` holds the add/edit logic.
- `EzBookkeepingTests`: unit tests for parsing and formatting. `EzBookkeepingUITests/ScreenshotTests`:
  the walkthrough against a seeded server.

## What links the repositories

- `SERVER_REF` names the server branch, tag or commit this version of the app is tested against
  (normally `main`). The `screenshots` job in `.github/workflows/build.yml` checks that server out,
  builds it, seeds it with `scripts/seed-test-server.sh` (a copy of the Android app's) and runs
  `ScreenshotTests` on an iPhone simulator.
- The job also runs nightly and on a `server-updated` repository dispatch. The server repository only
  sends that dispatch to the Android app so far; to include this app, its `notify-android-app.yml` needs a
  second request to `ssiuuk/ezbookkeeping-ios` with a token that can write to this repository.
  When a scheduled or dispatched run fails, it opens (or comments on) the issue
  "The app test fails against the latest server".
- The job can be started by hand from the Actions tab with any `server_ref`.

## Changes that need both sides

When a feature needs a server change (a new API field or endpoint) as well as an app change:

1. Make the server change in ssiuuk/ezbookkeeping on its own branch and open its pull request there.
2. In this repository, set `SERVER_REF` to that server branch in the app's pull request, so CI tests
   the two together.
3. After the server pull request is merged, set `SERVER_REF` back to `main` before merging the app one.

Keep the app working against servers without the fork's additions where it is cheap to do so: the
app hides books, projects and merchants when those endpoints answer 404.

When an API the app calls changes on the server (request or response fields in `pkg/models`, routes
in `cmd/webserver.go`), update `EzBookkeeping/Models` and the requests in `EzBookkeeping/Views` here,
and the Android app's `data/` package there.

## Building and checking

- Builds and tests only run on macOS (GitHub Actions `macos-latest`); cloud sessions have no Xcode.
  There, `swiftc -parse` on all Swift files catches syntax errors, and the Foundation-only files
  (`Models`, `API`, `Support` except `Colors`/`Keychain`, `AppState`, `TransactionEditModel`) can be
  type-checked and the unit tests run with a Linux Swift toolchain (for example the `swift` Docker image)
  if `SwiftUI`/`Combine`/`Keychain`/`WebSession` are replaced by small stubs.
- Use only APIs available in iOS 17, and add `.accessibilityIdentifier`s the UI test relies on when
  changing a screen it visits.
- Pull requests from this repository publish `screenshots.zip` to the `ios-preview` release.
- `.github/workflows/testflight.yml` signs and uploads to TestFlight on a `v*` tag (version from the tag,
  build number from the run number), on the Mac named by the `IOS_RELEASE_RUNNER` variable or
  `macos-latest`. Its secrets are listed in the README's "TestFlight releases" section.
