#!/usr/bin/env bash
set -euo pipefail

# REQUIRED
export PM_TOKEN="${PM_TOKEN:-}"

# OPTIONAL TUNING
export PM_SIDE="${PM_SIDE:-buy}"
export PM_AMOUNT_USDC="${PM_AMOUNT_USDC:-2}"
export PM_SIG="${PM_SIG:-eoa}"
export DRY_RUN="${DRY_RUN:-true}"
export POLL_MS="${POLL_MS:-600}"
export MOMENTUM_WINDOW_MS="${MOMENTUM_WINDOW_MS:-10000}"
export TRIGGER_PCT="${TRIGGER_PCT:-0.20}"
export MISMATCH_PCT="${MISMATCH_PCT:-1.5}"
export COOLDOWN_MS="${COOLDOWN_MS:-300000}"
export MAX_TRADES="${MAX_TRADES:-10}"
export MAX_LOSS_USDC="${MAX_LOSS_USDC:-8}"

if [[ -z "$PM_TOKEN" ]]; then
  echo "Set PM_TOKEN first."
  exit 1
fi

node /home/claw/.openclaw/workspace/memory/binance_poly_latency_bot.mjs
