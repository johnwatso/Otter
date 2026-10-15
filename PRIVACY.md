# Privacy

Otter is a local macOS utility. It has no account system, telemetry, or
advertising SDKs, and it does not operate a service that receives your share
configuration or diagnostic data.

## Data Otter stores on your Mac

- Share configuration such as names, server addresses, mount paths,
  connection rules, learned fallback addresses, pause state, and app
  preferences are stored in the app's local preferences.
- Recent connection events and response-time history are stored locally to
  show activity and reliability information.
- SMB credentials remain in macOS Keychain. Otter uses the system credential
  flow and does not put passwords in share URLs or ordinary configuration
  exports.
- A protected backup can include eligible SMB credentials only when you
  explicitly choose that option and protect the backup with a password.

## Network and permissions

Otter connects to the servers you configure and may use local-network
discovery, reachability checks, Wake-on-LAN, DNS or Bonjour resolution, and
VPN status to keep those shares available. Location Services is requested
only when a Wi-Fi-name rule needs the current network name. Local Network,
Notifications, and Location Services permissions can be denied; the relevant
feature will then be unavailable or reduced as described in the app.

If automatic update checks are enabled, Sparkle retrieves Otter's public
appcast and, when an update is available, its signed release archive. Those
requests go to Otter's public update host and GitHub's release hosting. Otter
does not send share names, credentials, diagnostics, or usage data with an
update check.

## Exports and support

Configuration export excludes credentials and private runtime state. Diagnostic
exports are created only when you request them and are redacted, but may still
contain useful technical context such as macOS and Otter versions,
measurements, and network characteristics. Review every export before sharing
it. See [SUPPORT.md](SUPPORT.md) for safe bug-reporting guidance.

## Changes and contact

Privacy changes are made in this file and recorded in Git history. For a
privacy question or concern, open a private GitHub security advisory using
the process in [SECURITY.md](SECURITY.md).
