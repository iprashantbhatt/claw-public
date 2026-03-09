#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/claw/.openclaw/workspace/memory
LOG=/home/claw/.openclaw/workspace/memory/TRADING-LOG.md
source "$ROOT/weather_profile.env"

sig=${SIGNATURE_TYPE:-eoa}
entry=${ENTRY_THRESHOLD:-0.15}
max_pos=${MAX_POSITION_USDC:-2}
max_trades=${MAX_TRADES_PER_SCAN:-5}
interval=${SCAN_INTERVAL_SEC:-120}

cities_csv=${TARGET_CITIES:-NYC,Chicago,Seattle,Atlanta,Dallas,Miami}
IFS=',' read -r -a cities <<< "$cities_csv"

get_bal(){ ~/.local/bin/polymarket clob balance --asset-type collateral --signature-type "$sig" -o json 2>/dev/null | sed -n 's/.*"balance": "\([0-9.]*\)".*/\1/p' | head -n1; }

while true; do
  TS=$(date -u '+%Y-%m-%d %H:%M UTC')
  bal=$(get_bal || true)
  if [[ -z "$bal" ]]; then
    echo "## $TS (weather-scan)" >> "$LOG"
    echo "- HOLD: balance read failed." >> "$LOG"
    sleep "$interval"
    continue
  fi

  placed=0
  for city in "${cities[@]}"; do
    [[ $placed -ge $max_trades ]] && break
    # Pull weather-related markets for city
    out=$(~/.local/bin/polymarket -o json markets search "$city weather temperature" 2>/dev/null || true)
    # Find first active + open binary market with YES price <= entry threshold
    line=$(echo "$out" | tr '\n' ' ' | sed 's/},/}\n/g' | grep -E '"active": true' | grep -E '"closed": false' | grep -E '"outcomePrices": "\["' | head -n 20 | \
      awk -v e="$entry" '
      {
        yes=0;
        if (match($0, /"outcomePrices": "\[\"([0-9.]+)\",\"([0-9.]+)\"\]"/, a)) yes=a[1]+0;
        if (yes>0 && yes<=e) print $0;
      }' | head -n1)

    if [[ -z "$line" ]]; then
      continue
    fi

    token=$(echo "$line" | sed -n 's/.*"clobTokenIds": "\["\([^"]*\)","\([^"]*\)"\]".*/\1/p')
    q=$(echo "$line" | sed -n 's/.*"question": "\([^"]*\)".*/\1/p')

    if [[ -n "$token" ]]; then
      if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "## $TS (weather-scan)" >> "$LOG"
        echo "- DRY_RUN BUY YES: city=$city question=$q token=$token amount=${max_pos}" >> "$LOG"
      else
        res=$(~/.local/bin/polymarket clob market-order --token "$token" --side buy --amount "$max_pos" --signature-type "$sig" -o json 2>&1 || true)
        echo "## $TS (weather-scan)" >> "$LOG"
        echo "- BUY YES: city=$city question=$q token=$token amount=${max_pos}" >> "$LOG"
        echo "- Result: $res" >> "$LOG"
      fi
      placed=$((placed+1))
    fi
  done

  if [[ $placed -eq 0 ]]; then
    echo "## $TS (weather-scan)" >> "$LOG"
    echo "- HOLD: no weather setup matched entry<=${entry}. balance=${bal}" >> "$LOG"
  fi

  sleep "$interval"
done
