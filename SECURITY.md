# Security

Rapto runs with Accessibility and Screen Recording permissions, so security reports are
taken seriously.

## Reporting a vulnerability

Please do not open a public issue. Report it privately in one of these ways:

- Use **Report a vulnerability** on the repository's Security tab (GitHub private
  vulnerability reporting).
- Email **support@rapto.app**.

Include the Rapto and macOS versions, what an attacker could do, and steps to reproduce.
You will get a reply within a few days. Please give us reasonable time to release a fix
before publishing details.

## Supported versions

Only the latest release is supported. Rapto updates itself through Sparkle; updates are
signed with an EdDSA key and the app is signed with a Developer ID and notarized by Apple.

## Scope

In scope: anything that lets another app or a remote party misuse Rapto's permissions,
read data through Rapto, tamper with updates, or run code through the AppleScript
commands or the settings import.

Out of scope: problems that require an attacker who already has full control of your user
account, and bugs in macOS itself.
