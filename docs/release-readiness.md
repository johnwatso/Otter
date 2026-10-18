# Release readiness

ShipHook owns Otter's release publishing, signing, notarization, GitHub
release, and Sparkle appcast update. This checklist covers the source and
product checks that must be complete before handing a commit to ShipHook.

## Automated gate

GitHub Actions must be green for the intended commit. It runs the Debug test
suite and an unsigned universal Release build. The unsigned build verifies
that Release-only compiler settings and Debug-only screenshot helpers cannot
break the artifact ShipHook produces.

Run the same checks locally with:

```sh
xcodebuild test -project Otter.xcodeproj -scheme Otter \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

xcodebuild build -project Otter.xcodeproj -scheme Otter \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' CODE_SIGNING_ALLOWED=NO
```

## Manual release matrix

Use a non-production test share and a test VPN account. Record the macOS
version, Mac architecture, protocol, and any result that differs from the
expected behavior.

- Fresh install: move the signed app to Applications, open it, complete
  onboarding, and confirm the menu bar item remains after closing its window.
- Upgrade: install over a prior Otter version and confirm shares, connection
  modes, pauses, preferences, event history, and scheduled-update settings
  survive.
- Permissions: test both allow and deny paths for Local Network,
  Notifications, and Location Services. Wi-Fi-name rules may be unavailable
  without Location Services; subnet rules must continue to work.
- Protocols: Otter 1.0 supports SMB. Mount and reconnect representative SMB
  shares (including an alias such as `server.local`) and verify the Finder
  credential flow without placing a password in a share URL. NFS and WebDAV
  are not supported yet.
- Resilience: exercise sleep/wake, Wi-Fi changes, an unavailable server, a
  manual disconnect, a VPN-only share, and an explicitly paused share.
- Background behavior: enable launch at login, sign out or restart, then
  verify that Otter resumes monitoring without opening a window.
- Architecture: complete the fresh-install and reconnect checks on both
  Apple silicon and Intel hardware.

## ShipHook handoff

Before publishing, give ShipHook the exact green commit and the intended
marketing version. After it completes, verify the generated archive rather
than a locally built substitute:

```sh
codesign -dv --verbose=4 /path/to/Otter.app
spctl --assess --type execute --verbose=4 /path/to/Otter.app
```

Confirm that the artifact is universal, signed with the expected Developer ID
identity, notarized, and stapled. Then install the published release over the
previous public version and use **Check for Updates** to verify that Sparkle
offers the new build. Confirm the website download button, GitHub asset,
appcast version/build, signature, file size, and release notes all describe
the same release.
