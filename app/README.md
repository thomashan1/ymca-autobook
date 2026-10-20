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
(`CloudRecords.swift`), the entry point (`AppMain.swift`), the away.yml splitter
and the resources. iOS can't wake an app at a precise instant, which is why the
booking happens on the Mac.

Three tabs, the same on the Mac and on iPhone/iPad (since 1.1):

| Screen | Shows |
|----------|----------------|
| **Schedule** | The next two weeks of your classes, one line each: booked, books on…, skipped or away, with a countdown to the next one that books. Swipe (iPhone) or click (Mac) a class to skip, cancel or stop booking it every week. **Away dates** opens from here. iPad and Mac show it as a calendar too |
| **Classes** | **Every week** (your lineup, each with how fast it fills) and **Just once**. **Add a class** opens every class at all nine branches for about two weeks: add it every week or just once (iCloud mode). Links to the full fill-speed table; the Mac also has **Browse weekly slots** |
| **Settings** | Data source, the Mac's status, **Booking history** (each opening's timing and result), GitHub (advanced) |

## Booking and cancelling single classes

Besides the weekly lineup, any single upcoming session can be booked or cancelled:
under Classes → **Add a class** (and by swiping or clicking a class in Schedule). One shared rule (`SessionState` in `Shared/ClassPicks.swift`) decides
what each session offers:

| The session is… | Action |
|---|---|
| booked | **Cancel** (asks first; then re-reads to confirm the seat is gone) |
| open for booking, seats left | **Book** now |
| not open yet | **Book**: queued, booked at the second its window opens, like the lineup |
| queued | **Undo** |
| in the weekly lineup, not open yet | **Skip** this one. With a GitHub repo set on the Mac, the skip is also written to `swaps.yml` so the GitHub backup skips it too (token needs Contents: Read and write) |
| skipped | **Unskip** |

The Mac does all the booking. The iPhone writes a `BookRequest` record to iCloud; the
Mac reads the zone's change feed every 30 s, acts and deletes the request. The Mac
publishes the upcoming schedule (one `Schedule.<branch id>` record per branch, e.g. `Schedule.1392`, refreshed every plan; all nine branches in one record would come close to iCloud's 1 MB limit),
its queue (`OneOff`) and skips (`Skip`). A result shows up as an `Opening` record, so it
gets the same alert as a lineup booking. Cancelling a lineup session before its window
opens also skips it, so the Mac doesn't book it back.

## Two data sources: your Mac (default) or GitHub

- **Mac** (the default) reads iCloud container `iCloud.com.thomashan.ybooker`
  (private database, zone `YBooker`): classes, away dates, swaps, fill speed, the
  real booking list (refreshed on every Mac plan) and each booking window's result.
  It needs no GitHub token. Booking and cancelling single classes and adding or
  removing away dates go through the Mac (an `AwayRequest` record the Mac applies
  and deletes); removing lineup classes is hidden. A CloudKit
  subscription sends an alert for every booking result
  (`iOS/Services/CloudSource.swift`; text via `Localizable.strings`).
- **GitHub** (Settings → Advanced → **Use GitHub instead**) is the advanced setup
  (README Option B). The app then reads `classes.yml`, `away.yml`, `swaps.yml` (all in the private repo),
  `bookings.json` and `schedule_snapshot.json` from the two repos, writes
  `away.yml`, opens auto-merging PRs to remove classes, and dispatches `book.yml`
  for "Book now".

Switching sources changes only what the app shows. It doesn't turn either booker
on or off.

## The Mac booker

- **Sign-in:** your YMCA (egym) login lives in the login Keychain, under service
  `com.thomashan.ybooker.mac`, a name kept from when the Mac app was separate. Local
  files live in `~/Library/Application Support/YBookerMac`.
- **Classes, away dates and one-day changes** are kept and edited on the Mac
  (Classes, and Schedule → Away dates; the same tabs as on the iPhone). It needs no GitHub account. Weekly
  classes and away dates can also be added and removed on the iPhone and iPad: the phone sends a
  request through iCloud and the Mac applies it (`addWeekly`/`removeWeekly` requests since 1.1, #148).
- **GitHub backup (optional, Settings → For technical users):** off by default. Turned on with a
  private repo and a token (Contents: Read and write on that repo only), the Mac
  writes `classes.yml`, `away.yml` and `swaps.yml` there after every change, one
  way, so the Option B GitHub booker can back it up. Turning it off forgets the repo
  and token.
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
