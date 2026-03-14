# Security Policy

## Reporting
If you find a security issue in this repository, open a private security report or contact the maintainer directly.

## Scope
This repository should contain only sanitized, public-safe artifacts.

## Never commit
- API keys / PAT tokens
- Wallet private keys / seed phrases
- Personal memory or trading logs with private context

## Security Monitoring

This project uses an automated security monitoring script (`security-monitor.sh`) that runs on each commit to:
- Detect accidental exposure of GitHub PATs or other secret tokens.
- Prevent committing of `memory/` files or other sensitive extensions.
- Run `git-secrets` scans when available.

All commits are required to pass this check.