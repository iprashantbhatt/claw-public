# claw-public

Public-safe automation scripts for prediction-market research and scanner orchestration.

## Included
- `scripts/safe_mode_24h_scanner.py`
- `scripts/safe_mode_24h_scanner.sh`
- `scripts/weather_strategy_scanner.sh`
- `scripts/polymarket_orchestrator.sh`
- `scripts/binance_poly_latency_bot.mjs`
- `scripts/run_latency_bot.sh`

## Safety notes
This public repo intentionally excludes:
- personal memory files
- trading logs / PnL reports
- environment files and tokens
- private user context

Review scripts before production use.

## Quick usage

```bash
# Example (review script before running)
chmod +x scripts/safe_mode_24h_scanner.sh
./scripts/safe_mode_24h_scanner.sh
```

## Public repo policy
This repository is intentionally sanitized. Operational logs, personal memory, and private credentials must stay in private storage.
