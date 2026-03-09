#!/usr/bin/env bash
set -u
LOG="/home/claw/.openclaw/workspace/memory/TRADING-LOG.md"
mkdir -p "$(dirname "$LOG")"

echo "" >> "$LOG"
echo "## $(date -u '+%Y-%m-%d %H:%M UTC')" >> "$LOG"
echo "- Orchestrator loop started (interval: 5m scans, 1h PnL checks)." >> "$LOG"

last_pnl=0

while true; do
  ts="$(date -u '+%Y-%m-%d %H:%M UTC')"

  # Scan markets
  scan_output=$(python3 - <<'PY'
import json,subprocess,sys
try:
    out=subprocess.check_output(['polymarket','markets','list','--active','true','--closed','false','--limit','500','-o','json'],text=True)
    markets=json.loads(out)
    ops=[]
    for m in markets:
        try:
            p=m.get('outcomePrices')
            prices=json.loads(p) if isinstance(p,str) else (p or [])
            prices=[float(x) for x in prices]
            if len(prices)>=2:
                s=sum(prices)
                if s<0.98:
                    ops.append({
                        'sum':s,
                        'id':m.get('id'),
                        'question':m.get('question'),
                        'prices':prices,
                        'clobTokenIds':m.get('clobTokenIds')
                    })
        except Exception:
            continue
    ops=sorted(ops,key=lambda x:x['sum'])
    print(json.dumps({'markets_scanned':len(markets),'opportunities':ops[:5]}))
except Exception as e:
    print(json.dumps({'error':str(e)}))
PY
)

  echo "" >> "$LOG"
  echo "## $ts" >> "$LOG"
  echo "- Scan result: $scan_output" >> "$LOG"

  # Execute if opportunities found (requires auth)
  opp_count=$(python3 - <<PY
import json
obj=json.loads('''$scan_output''')
print(len(obj.get('opportunities',[])))
PY
)

  if [ "$opp_count" -gt 0 ]; then
    echo "- Arbitrage opportunities found. Attempting execution path." >> "$LOG"
    echo "- ACTION REQUIRED: Command John to execute via polymarket clob market-order using identified token IDs." >> "$LOG"
    # Safety gate: do not auto-trade without valid authenticated account in this environment.
    echo "- Safety gate active: no auto-order submitted by orchestrator script." >> "$LOG"
  else
    echo "- No arbitrage opportunities (sum < 0.98) found." >> "$LOG"
  fi

  # Hourly PnL check
  now=$(date +%s)
  if [ $last_pnl -eq 0 ] || [ $((now-last_pnl)) -ge 3600 ]; then
    pnl_out=$(polymarket clob balance --asset-type collateral -o json 2>&1 || true)
    echo "- Hourly PnL check: $pnl_out" >> "$LOG"
    last_pnl=$now
  fi

  sleep 300
done
