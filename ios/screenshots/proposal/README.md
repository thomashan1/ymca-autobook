# Standalone-app proposal mockups

Concept screens for the **standalone iOS app** discussed in the tracking issue —
the version where booking runs on-device instead of on GitHub Actions. These are
mockups of screens that **do not exist yet**; the shipped app's real screenshots
live one directory up.

| File | Screen | Why it's new |
|------|--------|--------------|
| `01-gym-picker.png` | Gym picker | Today's engine hardcodes one gym (`silicon-valley-ymca-…` + `ymca-silicon-valley.fisikal.com`). A distributable app has to discover the gym. |
| `02-sign-in.png` | Gym sign-in | Replaces `EGYM_USERNAME`/`EGYM_PASSWORD` secrets with a `WKWebView` SSO flow, so the app holds a session cookie and never the password. |
| `03-engine.png` | Engine | Replaces the Jobs tab. Shows the on-device scheduler and which wake-up tiers are armed per class. |
| `04-storage.png` | Your data | `classes.yml` / `pauses.yml` / `bookings.json` become iCloud records instead of files in two Git repos. |

`mockups.html` is the source. Regenerate the PNGs with:

```bash
python3 - <<'PY'
from playwright.sync_api import sync_playwright
import pathlib
src = pathlib.Path('ios/screenshots/proposal')
names = {'shot-gym':'01-gym-picker', 'shot-signin':'02-sign-in',
         'shot-engine':'03-engine', 'shot-storage':'04-storage'}
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={'width': 402, 'height': 874}, device_scale_factor=3)
    pg.goto('file://' + str((src / 'mockups.html').resolve()))
    pg.wait_for_timeout(700)
    for sel, name in names.items():
        pg.locator('#' + sel).screenshot(path=str(src / f'{name}.png'))
    b.close()
PY
```
