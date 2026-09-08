# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue, PR,
or discussion for anything security-sensitive.

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/BuLEEto/Runa/security/advisories/new)
(also reachable from the repository's **Security** tab). This opens a private
advisory visible only to the maintainers.

Please include enough to reproduce — a minimal font and/or text input, and what
you observed (crash, hang, out-of-bounds read/write, unexpected allocation, etc.).

## Supported versions

Fixes land on `main` and the latest `vX.Y.Z` release tag — please reproduce
against the newest tag before reporting.

## Scope

runa parses untrusted fonts (OpenType / TrueType / CFF / COLR) and shapes
untrusted text, so parsing, shaping, normalization, and raster bugs that crash,
hang, or read/write out of bounds — or trigger unbounded allocation — are in
scope.
