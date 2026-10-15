# Notes for AI agents working on Otter

## Keep the website screenshots in step with the app

The Manage Shares window (the share list, status header, Reliability strip and
detail cards) is pictured on the website and in the README:

- `website/assets/otter-app-light.png`
- `website/assets/otter-app-dark.png`
- `README.md` uses the light image.

If you change how that window looks (layout, sidebar rows, header, cards,
spacing, copy), recapture both images in the same change so the website never
shows an out-of-date UI. Onboarding and other screens are not shown on the site.

### How to recapture

1. Build the Debug app. Work on a copy under a different bundle ID so your real
   shares and settings are untouched (copy `Otter.app`, change
   `CFBundleIdentifier` with PlistBuddy, `codesign --force --deep -s -`).
2. Launch it with a forced appearance, once per image:
   `open -n OtterShot.app --args -OtterAppearance light` (or `dark`).
   This option is Debug-only; do not change the system appearance.
3. In Settings → Advanced → Developer, turn on **Show demo shares**. The demo
   data lives in `ScreenshotDemo` in `Otter/App/AppModel.swift`: six healthy
   shares, one deliberately away from its home network, and a week of
   reliability data. Update it if the screenshot needs different content.
4. Select the **Media** share, bring the window to the front (an inactive window
   renders greyed out), then capture it with its window ID:
   `screencapture -l <windowID> out.png`.
5. Replace both PNGs in `website/assets/`, and keep the `width`/`height`
   attributes on the `<img>` tags in `website/index.html` matching the new size.
