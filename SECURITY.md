# Security boundaries

Otter is a local network-share utility, not a security product, identity
provider, secret manager, or hosted service. It does not operate an account
system, accept connections from the internet, or provide a security boundary
around the files on a mounted share.

Use macOS Keychain and your share or VPN provider to manage authentication.
Otter asks macOS to use an existing SMB credential; it does not ask you to put
a password in a share URL. The optional protected backup is the one exception:
when you explicitly create it, it can include eligible SMB credentials inside
a password-encrypted file. Treat that file and its password as sensitive.

## What to report privately

Use GitHub's [private vulnerability reporting form](https://github.com/johnwatso/Otter/security/advisories/new)
only for a defect in Otter that could, without your intended action:

- expose an SMB credential or protected backup;
- disclose data that Otter says it excludes from a configuration or diagnostic
  export;
- execute an unexpected local command or mount an attacker-controlled location;
- modify Otter configuration or local files outside the action you requested.

Include the Otter and macOS versions, minimal reproduction steps, and a
description of the impact. Do not include passwords, backup passwords, access
tokens, private share URLs, or unredacted diagnostic reports.

## Out of scope

The following are not vulnerabilities in Otter itself:

- access controls, encryption, availability, or data loss on an SMB, NFS, or
  WebDAV server;
- the security of a VPN provider, Finder, macOS, Keychain, Sparkle, or a
  third-party network client;
- a compromised Mac, home network, server, VPN, or account;
- requests to make Otter store, transmit, or protect secrets beyond the
  macOS-provided mechanisms it already uses.

For normal setup and reliability help, use [SUPPORT.md](SUPPORT.md) instead.
