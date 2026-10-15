# YMCA Booker: one app for Mac, iPhone and iPad

One SwiftUI app (bundle `com.thomashan.ymcaautobook`) with a different job on each
platform:

- **Mac: the booker.** It runs from the menu bar, plans every 3 hours, wakes just
  before each booking window opens (`occurs_at − 167h`), books at that second, and
  publishes everything to the user's own iCloud. It's in `YmcaAutobook/macOS/`.
- **iPhone and iPad: the viewer.** It shows the week, your classes, fill speed, away
  dates and the Mac's results, and sends an alert after each booking. It's in
  `YmcaAutobook/iOS/`.

Both platforms share `YmcaAutobook/Shared/`: the iCloud record shapes
(`CloudRecords.swift`), the entry point (`AppMain.swift`), the pauses.yml splitter
and the resources. iOS can't wake an app at a precise instant, which is why the
booking happens on the Mac.

| Screen (iPhone/iPad) | Shows |
|----------|----------------|
| **Week**    | Two weeks of classes merged with your real bookings (room, instructor, end time) |
| **Classes** | **Book**: every class at both branches for about two weeks, to book or cancel one at a time (iCloud mode only). **Weekly**: your recurring lineup and how fast each class fills |
| **Upcoming** | **Openings**: countdowns to each booking window, the Mac's status and each booking result. **Away**: away dates and one-off swaps |
| **Settings** | Data source, the Mac's status, GitHub (advanced) |

## Booking and cancelling single classes

Besides the weekly lineup, any single upcoming session can be booked or cancelled:
on the Mac under Settings → **Book**, on iPhone and iPad under Classes → **Book**. One shared rule (`SessionState` in `Shared/ClassPicks.swift`) decides
what each session offers:

| The session is… | Action |
|---|---|
| booked | **Cancel** (asks first; then re-reads to confirm the seat is gone) |
| open for booking, seats left | **Book** now |
| not open yet | **Book**: queued, booked at the second its window opens, like the lineup |
| queued | **Undo** |
| in the weekly lineup, not open yet | **Skip** this one (Mac only; a GitHub backup still books it) |
| skipped | **Unskip** |

The Mac does all the booking. The iPhone writes a `BookRequest` record to iCloud; the
Mac reads the zone's change feed every 30 s, acts and deletes the request. The Mac
publishes the upcoming schedule (one `Schedule.current` record, refreshed every plan),
its queue (`OneOff`) and skips (`Skip`). A result shows up as an `Opening` record, so it
gets the same alert as a lineup booking. Cancelling a lineup session before its window
opens also skips it, so the Mac doesn't book it back.

## Two data sources: your Mac (default) or GitHub

- **Mac** (the default) reads iCloud container `iCloud.com.thomashan.ybooker`
  (private database, zone `YBooker`): classes, away dates, swaps, fill speed, the
  real booking list (refreshed on every Mac plan) and each booking window's result.
  It needs no GitHub token. Booking and cancelling single classes go through the Mac
  (above); removing lineup classes and away-date edits are hidden. A CloudKit
  subscription sends an alert for every booking result
  (`iOS/Services/CloudSource.swift`; text via `Localizable.strings`).
- **GitHub** (Settings → Advanced → **Use GitHub instead**) is the advanced setup
  (README Option B). The app then reads `classes.yml`, `pauses.yml`, `swaps.yml`,
  `bookings.json` and `schedule_snapshot.json` from the two repos, writes
  `pauses.yml`, opens auto-merging PRs to remove classes, and dispatches `book.yml`
  for "Book now".

Switching sources changes only what the app shows. It doesn't turn either booker
on or off.

## The Mac booker

- **Sign-in:** your YMCA (egym) login lives in the login Keychain, under service
  `com.thomashan.ybooker.mac`, a name kept from when the Mac app was separate. Local
  files live in `~/Library/Application Support/YBookerMac`.
- **Away dates and swaps:** read from an optional private GitHub repo
  (Settings → General); editing them in the app is #148.
- **Open at login:** on by default. The app re-registers itself on every launch,
  so this keeps working if the app moves.
- **Moving over from the old app:** the first launch copies the old app's settings
  (`com.thomashan.ybooker.mac` defaults) once.

## GitHub mode: token

In GitHub mode, the app stores a **fine-grained GitHub PAT** in the Keychain (`KeychainStore`) with:

- `contents: read/write` on `thomashan1/ymca-autobook` and `thomashan1/ymca-private`
- `pull requests: read/write` (deleting a class opens an auto-merging PR)
- `actions: read/write` (run history + dispatch) and `workflows: write`

> ⚠️ A PAT baked into a TestFlight build gives every tester write access to your
> repos. Before distributing beyond yourself, move writes behind a small
> Cloudflare Worker that holds the token server-side and exposes a scoped API.
> `GitHubClient` is written so its base URL / auth header can be swapped for the
> Worker with no change to the feature code.

## Build and test

The `.xcodeproj` is committed. Folders are synced, so a new file under
`YmcaAutobook/` or `YmcaAutobookTests/` is picked up without editing the project.
Each file is wrapped in `#if os(iOS)` or `#if os(macOS)` unless both platforms
share it. Minimum versions are iOS 17 and macOS 14.

```bash
open app/YmcaAutobook.xcodeproj           # pick "My Mac" or a device, then ⌘R
# tests: macOS (Mac engine + the iCloud contract) and an iOS simulator (parsers)
xcodebuild -project app/YmcaAutobook.xcodeproj -scheme YmcaAutobook -destination 'platform=macOS' test
xcodebuild -project app/YmcaAutobook.xcodeproj -scheme YmcaAutobook -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Under XCTest the app starts as an empty shell (`AppMain`), so tests never log in,
book anything or touch iCloud. `CloudRecordsTests` checks that every record the
Mac writes decodes on the iPhone with the same values.

## Layout

```
app/
  YmcaAutobook.xcodeproj      one target for iOS + macOS, plus the test target
  Config/                     entitlements per platform (iCloud; push on iOS)
  YmcaAutobook/
    Shared/                   AppMain, CloudRecords, FlowMapping, resources
    macOS/                    the booker: App, Engine, UI, Fisikal client
    iOS/                      the viewer: App, Features, Models, Services, Support
  YmcaAutobookTests/          XCTest, per-platform files
  screenshots/
```
