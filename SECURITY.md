# Security policy

## Supported version

Security fixes are made in the current `main` branch and the newest APK produced by the release pipeline.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose a vault, password, OAuth token or MCP token. Do not attach a KDBX database, screenshots of secrets, `.env`, Android keystores, or application logs containing private values.

Until the GitHub repository has a private vulnerability-reporting channel, contact the project maintainer through a private channel agreed for the project. Include a minimal reproduction with synthetic data, affected app version, Android version and the security impact.

## Scope notes

- The MCP server is intentionally disabled by default. Treat its bearer token as a password.
- A public OAuth Client ID is safe to distribute; a Yandex OAuth client secret is not. The Android app does not use or contain a client secret.
- APKs must be signed with a protected production signing key before public distribution.
