#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/claw/.openclaw/workspace/memory
LOG="$ROOT/TRADING-LOG.md"
PROFILE="$ROOT/safe_mode_profile.env"
[[ -f "$PROFILE" ]] && source "$PROFILE"

SIG_TYPE=${SIGNATURE_TYPE:-eoa}
RUN_HOURS=${RUN_HOURS:-24}
SCAN_INTERVAL_SEC=${SCAN_INTERVAL_SEC:-120}
COOLDOWN_SEC=${COOLDOWN_SEC:-900}
MAX_DAILY_LOSS=${MAX_DAILY_LOSS:-15}
BASE_POSITION_USDC=${BASE_POSITION_USDC:-2}
MAX_POSITION_USDC=${MAX_POSITION_USDC:-10}
SIZING_SLOPE=${SIZING_SLOPE:-0.35}
MIN_YES_PRICE=${MIN_YES_PRICE:-0.35}
MAX_YES_PRICE=${MAX_YES_PRICE:-0.70}
MIN_VOL_24H=${MIN_VOL_24H:-5000}
MAX_HOURS_TO_EXPIRY=${MAX_HOURS_TO_EXPIRY:-96}

END=$(( $(date +%s) + RUN_HOURS*3600 ))
LAST_TRADE_TS=0
START_BAL=""
LAST_BAL=""

get_bal(){
  ~/.local/bin/polymarket clob balance --asset-type collateral --signature-type "$SIG_TYPE" -o json 2>/dev/null \
  | sed -n 's/.*"balance": "\([0-9.]*\)".*/\1/p' | head -n1
}

while [ "$(date +%s)" -lt "$END" ]; do
  NOW=$(date +%s)
  TS=$(date -u '+%Y-%m-%d %H:%M UTC')
  BAL=$(get_bal || true)

  if [[ -z "$BAL" ]]; then
    echo "## $TS (safe-scan)" >> "$LOG"
    echo "- HOLD: balance/API read issue." >> "$LOG"
    sleep "$SCAN_INTERVAL_SEC"
    continue
  fi

  if [[ -z "$START_BAL" ]]; then START_BAL="$BAL"; fi
  if [[ -z "$LAST_BAL" ]]; then LAST_BAL="$BAL"; fi

  DD=$(awk -v s="$START_BAL" -v b="$BAL" 'BEGIN{print s-b}')
  DD_HIT=$(awk -v dd="$DD" -v m="$MAX_DAILY_LOSS" 'BEGIN{print (dd>m)?1:0}')
  if [[ "$DD_HIT" -eq 1 ]]; then
    echo "## $TS (safe-scan)" >> "$LOG"
    echo "- HOLD: drawdown guard hit. start=$START_BAL current=$BAL max_loss=$MAX_DAILY_LOSS" >> "$LOG"
    sleep 300
    continue
  fi

  if [[ $((NOW - LAST_TRADE_TS)) -lt $COOLDOWN_SEC ]]; then
    echo "## $TS (safe-scan)" >> "$LOG"
    echo "- HOLD: cooldown active. balance=$BAL" >> "$LOG"
    sleep "$SCAN_INTERVAL_SEC"
    continue
  fi

  # Dynamic sizing: increases with positive equity drift from START_BAL, capped
  TRADE_SIZE=$(awk -v base="$BASE_POSITION_USDC" -v cap="$MAX_POSITION_USDC" -v slope="$SIZING_SLOPE" -v b="$BAL" -v s="$START_BAL" 'BEGIN{grow=(b>s)?(b-s):0; amt=base*(1+slope*grow); if(amt>cap) amt=cap; if(amt<0.5) amt=0.5; printf "%.2f", amt}')

  CAND_JSON=$(python3 - <<PY
import json, subprocess, math, datetime
min_yes=float("$MIN_YES_PRICE")
max_yes=float("$MAX_YES_PRICE")
min_vol=float("$MIN_VOL_24H")
max_hours=float("$MAX_HOURS_TO_EXPIRY")
now=datetime.datetime.now(datetime.timezone.utc)
cmd=['/home/claw/.local/bin/polymarket','-o','json','markets','list','--active','true','--closed','false','--limit','700']
try:
    out=subprocess.check_output(cmd,text=True,stderr=subprocess.DEVNULL)
    data=json.loads(out)
except Exception:
    print('{}')
    raise SystemExit(0)

best=None
for m in data:
    try:
        prices=m.get('outcomePrices')
        prices=json.loads(prices) if isinstance(prices,str) else prices
        tids=m.get('clobTokenIds')
        tids=json.loads(tids) if isinstance(tids,str) else tids
        if not isinstance(prices,list) or len(prices)!=2 or not isinstance(tids,list) or len(tids)!=2:
            continue
        yes=float(prices[0]); no=float(prices[1])
        vol=float(m.get('volume24hr') or 0)
        if vol < min_vol: continue
        if not (min_yes <= yes <= max_yes): continue
        end_date=m.get('endDate')
        if end_date:
            try:
                dt=datetime.datetime.fromisoformat(end_date.replace('Z','+00:00'))
                hrs=(dt-now).total_seconds()/3600
                if hrs <= 0 or hrs > max_hours:
                    continue
            except Exception:
                continue
        # prefer high liquidity and slight pricing imbalance near 0.5 edges
        edge=abs(yes-0.5)
        score=vol*(0.7+edge)
        row={
            'token':tids[0],
            'yes':yes,
            'no':no,
            'vol24':vol,
            'question':m.get('question','')[:220],
            'score':score
        }
        if best is None or row['score']>best['score']:
            best=row
    except Exception:
        continue
print(json.dumps(best or {}))
PY
)

  TOKEN=$(echo "$CAND_JSON" | sed -n 's/.*"token": "\([^"]*\)".*/\1/p')
  YESP=$(echo "$CAND_JSON" | sed -n 's/.*"yes": \([0-9.]*\).*/\1/p')
  VOL=$(echo "$CAND_JSON" | sed -n 's/.*"vol24": \([0-9.]*\).*/\1/p')
  Q=$(echo "$CAND_JSON" | sed -n 's/.*"question": "\([^"]*\)".*/\1/p')

  if [[ -z "$TOKEN" ]]; then
    echo "## $TS (safe-scan)" >> "$LOG"
    echo "- HOLD: no candidate matched filters yes[$MIN_YES_PRICE,$MAX_YES_PRICE] vol>=$MIN_VOL_24H. balance=$BAL" >> "$LOG"
    sleep "$SCAN_INTERVAL_SEC"
    continue
  fi

  RES=$(~/.local/bin/polymarket clob market-order --token "$TOKEN" --side buy --amount "$TRADE_SIZE" --signature-type "$SIG_TYPE" -o json 2>&1 || true)

  echo "## $TS (safe-scan)" >> "$LOG"
  echo "- Action: BUY YES amount=$TRADE_SIZE yes=$YESP vol24=$VOL token=$TOKEN" >> "$LOG"
  echo "- Market: $Q" >> "$LOG"
  echo "- Result: $RES" >> "$LOG"

  if echo "$RES" | grep -q '"success": true'; then
    LAST_TRADE_TS=$NOW
  fi

  LAST_BAL="$BAL"
  sleep 180
done
