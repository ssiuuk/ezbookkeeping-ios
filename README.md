# ezBookkeeping for iPhone

A native iOS app (SwiftUI) for your own ezBookkeeping server. The screens you use every day are native: overview, transactions, adding and editing transactions, accounts and settings, plus a Spending widget for the home screen. Less used pages (reports, budgets, categories, tags, family books and so on) open the server's mobile web pages inside the app, already signed in. Nothing is stored by a third party: the app only talks to the servers you add.

It is the iPhone counterpart of the [Android app](https://github.com/ssiuuk/ezbookkeeping-android) and makes the same requests to the same API.

You can add several servers and switch between them in **More → Settings → Manage servers**, for example a home server and a family one. On first launch the app asks for the server to connect to.

## What it does

- **Servers**: add, rename, remove and switch servers; the sign-in token of each is kept in the iOS Keychain.
- **Sign-in**: username or email and password, the two-factor passcode step, or **Sign in on the web page** for single sign-on or creating an account.
- **Overview**: spending and income this month, last month, today, this week and this year (converted to your default currency with the server's exchange rates), net assets and the latest transactions.
- **Transactions**: everything newest first, grouped by day, loading more while scrolling, with search. **Accounts**: balances grouped by kind; tap one for its transactions.
- **Add and edit**: expense, income or transfer; amount (typed on the app's own number pad, which has **+ − × ÷** next to the digits, so `12.50+3` or `3×4.20` can be typed; the result shows under the field, and OK turns into **=** to work it out; closing the pad or saving works it out too; hold delete to clear), category (including **Add a category**, in an existing or a new group), account(s), received amount for transfers between currencies, time, project, merchant (with suggestions and **Add a merchant**), tags, description and photos (take one or choose one; they are shrunk to 2048 pixels and uploaded right away, and tapping one removes it). A new transaction starts with the account you used last time at that shop, or else for that category or kind of transaction, remembered per server and book, unless you picked the account yourself.
- **To review**: purchases handed over by an Apple Pay automation in Shortcuts (see [Purchases to review](#purchases-to-review)) wait on the overview. Tapping one opens it in the add form with the amount, shop and date filled in, the account used with that card (or one named with the card's last four digits) and the category used at that shop; saving remembers both for next time. Swipe one away to dismiss it.
- **Offline**: the overview, transactions, accounts and the add form's lists show what the server last sent while it can't be reached, with a note saying when that was. Transactions added, changed or deleted meanwhile are kept on the phone, listed on the overview and sent in order as soon as the server answers again (also in the background). When a transaction was changed or deleted on the server meanwhile, the change is held back and tapping it shows what differs and lets you keep either version; changes the server refuses can be edited, retried or discarded. Moving a transaction to another book needs the server.
- **Spending widget**: small, medium and large sizes show the period's spending, income, two other periods, the latest transactions and buttons to add an expense, income or transfer or open the purchases to review. Long-press it → **Edit Widget** to choose the period, the book (the one the app shows, or a fixed one) and whether to hide amounts. It refreshes every 30 minutes, whenever the app changes something, and with its refresh button, and shows the app's offline copy while the server can't be reached. To load by itself, the widget reads the active server's address and sign-in token, which the app keeps in the shared app group container on the phone.
- **Family books**: switch the book the app shows, add a transaction to another book, or move an existing one to another book (with the server's `transactions/move/book.json`, or by adding it there and deleting the original on servers without it). Categories, accounts, tags and projects with the same names are picked in the new book.
- **More**: reports, budgets, household report, projects, categories, tags, templates, scheduled transactions, family books, exchange rates and the server's settings, as the server's own mobile pages.
- **Settings**: servers, sign-out, light, dark or system theme, and **Language**, which opens the app's page in the Settings app. The app is in the server's 22 languages (English, Chinese simplified and traditional, Dutch, French, German, Greek, Italian, Japanese, Kannada, Korean, Polish, Portuguese, Romanian, Russian, Slovenian, Spanish, Tamil, Thai, Turkish, Ukrainian and Vietnamese), with the Android app's wording where the two share a text.

Family books, projects and merchants need the server from [ssiuuk/ezbookkeeping](https://github.com/ssiuuk/ezbookkeeping); with other servers they are hidden (the app treats a 404 from those endpoints as "not supported").

### Purchases to review

The Android app reads Google Wallet's notifications; iOS doesn't let apps read other apps' notifications, so the iPhone gets purchases from a Shortcuts automation instead:

1. Open **Shortcuts** → **Automation** → **+** → **Wallet** (or **Transaction**), choose your cards, and pick **Run Immediately**.
2. Add the action **Add a purchase to review** (from ezBookkeeping), and set its **Amount**, **Merchant** and **Card** to the automation's **Amount**, **Merchant** and **Card** (tap each field and choose them from the Shortcut Input).

After each Apple Pay purchase it lands under **To review** on the overview. There is also an **Add a payment message to review** action, which reads the amount, shop and card from text such as a bank's message ("£4.50 at Corner Café with Visa •••• 1234"), for automations on messages or emails.

### Not in this version

- Balance changes and transactions you can't edit open the server's web page instead of the native form, as on Android.
- A transaction moved to another book with the add-then-delete fallback (servers without `transactions/move/book.json`) loses its photos.

## Install

Once TestFlight releases are set up (see [TestFlight releases](#testflight-releases)), install it with Apple's TestFlight app. Without them, the app runs on a simulator or on your own iPhone from Xcode:

1. On a Mac with Xcode 15 or later, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. In this folder run `xcodegen generate`, then open `EzBookkeeping.xcodeproj`.
3. To run on your iPhone, select the **EzBookkeeping** target, open **Signing & Capabilities**, tick **Automatically manage signing** and choose your team (a free Apple ID works for 7-day builds). The repository keeps simulator-only settings, so don't commit that change.
4. Open the app, enter your server address (for example `https://money.example.com` or `http://192.168.1.10:8080`) and sign in.

The app allows plain `http://` addresses, since self-hosted servers often run on a home network without TLS.

## TestFlight releases

`.github/workflows/testflight.yml` builds a signed app and uploads it to TestFlight whenever a tag `vX.Y.Z` is pushed or created on the GitHub releases page. The tag sets the version (`v1.2.0` → 1.2.0) and the workflow's run number sets the build number, which TestFlight needs to grow with every upload. It can also be started by hand from the Actions tab.

### One-time setup

**1. In App Store Connect** (with the paid developer account):

- Create the app (Apps → **+** → New App) with the bundle id `com.ssiuuk.ezbookkeeping`. Register the bundle id first under Certificates, Identifiers & Profiles → Identifiers if it isn't listed.
- Create an API key under Users and Access → Integrations → App Store Connect API, with the **App Manager** role. Download the `.p8` file (it can only be downloaded once) and note its Key ID and the Issuer ID shown above the list.

**2. Signing files** (on any Mac signed in to the account):

- An **Apple Distribution** certificate: Xcode → Settings → Accounts → your team → Manage Certificates → **+** → Apple Distribution. Then in Keychain Access, under My Certificates, right-click "Apple Distribution: …" → Export as a `.p12` with a password.
- An **App Group** `group.com.ssiuuk.ezbookkeeping`: Certificates, Identifiers & Profiles → Identifiers → **+** → App Groups. The app and its widget share the server they use, the purchases to review and the offline copy through it.
- Two identifiers with the **App Groups** capability set to that group: `com.ssiuuk.ezbookkeeping` (the app) and `com.ssiuuk.ezbookkeeping.widget` (the widget). Edit the app's identifier if it already exists.
- Two **App Store** provisioning profiles: Profiles → **+** → App Store Connect, one for each identifier, with that certificate. Download both `.mobileprovision` files. They and the certificate expire after a year; renew them and update the secrets then. Make the profiles after setting the App Group, or they won't include it.

**3. Repository secrets** (Settings → Secrets and variables → Actions → New repository secret):

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | the 10-character Team ID (Membership details on developer.apple.com) |
| `ASC_KEY_ID` | the API key's Key ID |
| `ASC_ISSUER_ID` | the Issuer ID |
| `ASC_KEY_P8` | the whole text of the `.p8` file |
| `DIST_CERT_P12_BASE64` | `base64 -i dist.p12 \| pbcopy`, then paste |
| `DIST_CERT_PASSWORD` | the `.p12` password |
| `PROVISIONING_PROFILE_BASE64` | the app's profile: `base64 -i app.mobileprovision \| pbcopy`, then paste |
| `WIDGET_PROVISIONING_PROFILE_BASE64` | the widget's profile, the same way |

**4. The Mac that builds it.** Without anything else the workflow uses GitHub's `macos-latest` runner. To build on your own Mac instead:

- It needs macOS with a current Xcode (open it once and accept the licence) and [Homebrew](https://brew.sh) (the workflow installs XcodeGen if it's missing). iOS apps can only be built on macOS, so a Linux or Windows server can't do this; keep GitHub's runner then.
- In this repository, Settings → Actions → Runners → **New self-hosted runner** → macOS, and run the commands it shows on the Mac. Run `./svc.sh install && ./svc.sh start` in the runner folder so it starts with the Mac.
- Add a repository **variable** (Settings → Secrets and variables → Actions → Variables) `IOS_RELEASE_RUNNER` with the value `["self-hosted", "macOS"]`. Only this workflow uses it; pull request builds stay on GitHub's runners, so other people's pull requests never run on your Mac.

The workflow signs with a keychain of its own and deletes it, the profile and the API key afterwards, so it doesn't touch the Mac's own keychain.

### Releasing

Create a release on the releases page with a new tag such as `v1.0.0` (or `git push origin v1.0.0`). When the workflow finishes, Apple takes 5 to 30 minutes to process the build; it then shows in App Store Connect → TestFlight. Add yourself and family under Internal Testing, and they install it with Apple's TestFlight app. The first build of a new version may ask for export compliance; the app already declares that it uses no non-exempt encryption.

## The server

The app talks to an ezBookkeeping server over its web API (`/api/...`), with the token as `Authorization: Bearer`, the phone's time zone as `X-Timezone-Offset` and `X-Timezone-Name`, and `X-Book-Id` when a family book is selected.

## Screenshots in CI

The `screenshots` job in `.github/workflows/build.yml` builds the server named in `SERVER_REF` from ssiuuk/ezbookkeeping, fills it with demo data (`scripts/seed-test-server.sh`, the same script as the Android app's) and runs the `ScreenshotTests` UI test on an iPhone simulator. It connects to `http://localhost:8080`, signs in as `demo` / `demo123456`, visits each screen, adds a transaction, edits it, adds a category, moves the transaction to the Family book and saves a purchase to review (put there by a launch argument, since Shortcuts can't run in a UI test), saving a screenshot at each step. The screenshots are uploaded as the `ezbookkeeping-ios-screenshots` artifact and, for pull requests from this repository, as `screenshots.zip` on the **iOS app (preview of an open pull request)** release (`ios-preview`).

It also runs nightly, whenever the server's `main` changes (a `server-updated` repository dispatch) and by hand from the Actions tab with any `server_ref`, and opens an issue "The app test fails against the latest server" if the app no longer works with the latest server.

macOS runners use GitHub Actions minutes ten times faster than Linux ones on private repositories; on a public repository they are free.

## Build and test locally

```sh
brew install xcodegen
xcodegen generate
xcodebuild test -project EzBookkeeping.xcodeproj -scheme EzBookkeeping \
  -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:EzBookkeepingTests
```

The build job also runs `scripts/check-strings.py`, which compares the strings the compiler finds in the code with `EzBookkeeping/Resources/Localizable.xcstrings` and fails when one is missing or not translated into every language. After adding or changing text, run it on your DerivedData folder with `--add` to put the new strings in the catalog, then translate them (Xcode's string catalog editor works), reusing the Android app's wording where it has the same text.

For the walkthrough, start a server on port 8080, run `bash scripts/seed-test-server.sh http://localhost:8080` and run the `EzBookkeepingUITests` tests the same way. Screenshots go to `$TMPDIR/ezb-screens` unless `TEST_RUNNER_SCREENSHOTS_DIR` is set.
