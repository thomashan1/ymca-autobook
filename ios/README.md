# YmcaAutobook — iOS app

A SwiftUI control panel for the `ymca-autobook` booking bot. It **does not book
classes itself** — the GitHub Actions engine keeps doing that at the exact
167-hour open instant. The app is a thin client that reads and steers that
state through the GitHub REST API:

| Screen   | Reads / writes |
|----------|----------------|
| **Week**    | Two-week calendar + agenda merging `classes.yml` with real bookings (`bookings.json`); durations from `schedule_snapshot.json` |
| **Classes** | `classes.yml` — regulars vs. trials; a toggle edits the file |
| **Jobs**    | Scheduled bookings + live 167h countdowns; recent run feed (Actions API) |
| **Away**    | `pauses.yml` in the private repo — add/remove away dates |

See the interactive concept mockup for the intended look.

## Why the app is a client, not the engine

iOS cannot reliably wake a backgrounded app at a precise instant, and booking
correctness depends on firing at `occurs_at − 167h`. So booking stays on GitHub
Actions. The app only:

- reads `classes.yml` (public repo)
- reads/writes `pauses.yml` (private repo)
- reads workflow run history for job status + the success/failure feed
- fires `workflow_dispatch` on `book.yml` for one-off "Book now"

No always-on backend is needed for v1.

## Auth

v1 stores a **fine-grained GitHub PAT** in the Keychain (`KeychainStore`) with:

- `contents: read/write` on `thomashan1/ymca-autobook` and `thomashan1/ymca-private`
- `pull requests: read/write` (deleting a class opens an auto-merging PR)
- `actions: read/write` (run history + dispatch) and `workflows: write`

> ⚠️ A PAT baked into a TestFlight build gives every tester write access to your
> repos. Before distributing beyond yourself, move writes behind a small
> Cloudflare Worker that holds the token server-side and exposes a scoped API.
> `GitHubClient` is written so its base URL / auth header can be swapped for the
> Worker with no change to the feature code.

## Build

The `.xcodeproj` is committed — just open it and run (⌘R). Min iOS 17.

```bash
open ios/YmcaAutobook.xcodeproj
```

Signing uses automatic code signing with the project's development team already
set. To run on a device, select your device and hit run; for wider testing,
Product → Archive → distribute to TestFlight (internal testing needs no App
Review).

## Layout

```
ios/
  YmcaAutobook.xcodeproj      committed Xcode project
  YmcaAutobook/
    App/                      entry point, root tab bar, theme tokens
    Models/                   GymClass, BookingJob, Pause
    Services/                 GitHubClient + repositories + Keychain
    Features/                 Week / Classes / Jobs / Away screens
    Support/                  Config (repo owner, names, endpoints)
```
