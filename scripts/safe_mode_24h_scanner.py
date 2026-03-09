#!/usr/bin/env python3
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

LOG = Path('/home/claw/.openclaw/workspace/memory/TRADING-LOG.md')
RUN_LOG = Path('/home/claw/.openclaw/workspace/memory/safe_mode_24h_scanner.out')
DURATION_SEC = 24 * 60 * 60
CYCLE_SEC = 5 * 60
MAX_RISK_USDC = 2.0
DRAWDOWN_LIMIT = 0.05
ERROR_BURST_THRESHOLD = 3
COOLDOWN_SEC = 30 * 60
SIG = ['--signature-type', 'eoa']


def ts():
    return datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')


def run_json(cmd):
    out = subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)
    return json.loads(out)


def append_log(lines):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open('a') as f:
        f.write(f"\n## {ts()}\n")
        for line in lines:
            f.write(f"- {line}\n")


def best_ask_from_book(book_obj):
    asks = book_obj.get('asks') or []
    if not asks:
        return None, None
    try:
        p = float(asks[0]['price'])
        s = float(asks[0]['size'])
        return p, s
    except Exception:
        return None, None


def scanner():
    start = time.time()
    error_streak = 0
    hold_only = False
    cooldown_until = 0

    bal = run_json(['polymarket', 'clob', 'balance', '--asset-type', 'collateral', '-o', 'json'] + SIG)
    start_balance = float(bal.get('balance', '0') or 0)

    append_log([
        'Safe-mode 24h scanner started.',
        'Mode: EOA only.',
        f'Initial collateral: {start_balance:.6f} USDC.',
        f'Risk guardrails: max {MAX_RISK_USDC:.2f} USDC/trade, max 1 open order, passive limits only, HOLD when uncertain.'
    ])

    while time.time() - start < DURATION_SEC:
        cycle_lines = [
            'Signature mode: EOA (`--signature-type eoa`).'
        ]
        now = time.time()
        if now < cooldown_until:
            mins_left = int((cooldown_until - now) / 60) + 1
            cycle_lines.append(f'Error cooldown active: skipping scans for ~{mins_left} more minute(s).')
            cycle_lines.append('Decision: HOLD (cooldown risk control).')
            append_log(cycle_lines)
            time.sleep(CYCLE_SEC)
            continue

        try:
            bal = run_json(['polymarket', 'clob', 'balance', '--asset-type', 'collateral', '-o', 'json'] + SIG)
            collateral = float(bal.get('balance', '0') or 0)
            dd = ((start_balance - collateral) / start_balance) if start_balance > 0 else 0.0
            cycle_lines.append(f'Collateral balance check: {collateral:.6f} USDC (drawdown {dd*100:.2f}% vs start).')

            if dd > DRAWDOWN_LIMIT:
                hold_only = True
                cycle_lines.append('Major state change: drawdown >5% detected; switched to HOLD-only mode.')

            open_orders = run_json(['polymarket', 'clob', 'orders', '-o', 'json'] + SIG)
            open_count = len((open_orders or {}).get('data', []) or [])
            cycle_lines.append(f'Open-order check: {open_count} open order(s).')
            if open_count >= 1:
                cycle_lines.append('Decision: HOLD (max 1 open order constraint).')
                append_log(cycle_lines)
                error_streak = 0
                time.sleep(CYCLE_SEC)
                continue

            markets = run_json([
                'polymarket', 'markets', 'list', '--active', 'true', '--closed', 'false', '--limit', '200', '-o', 'json'
            ] + SIG)

            candidates = []
            for m in markets:
                try:
                    if not m.get('acceptingOrders', False):
                        continue
                    liq = float(m.get('liquidityNum') or m.get('liquidity') or 0)
                    spr = float(m.get('spread') or 1)
                    token_ids = json.loads(m.get('clobTokenIds') or '[]')
                    if len(token_ids) != 2:
                        continue
                    if liq < 1000 or spr > 0.02:
                        continue
                    candidates.append((liq, m, token_ids))
                except Exception:
                    continue

            candidates.sort(key=lambda x: x[0], reverse=True)
            inspect = candidates[:10]
            cycle_lines.append(f'Market scan: {len(markets)} active pulled; {len(candidates)} candidates passed liquidity/spread filter; inspected {len(inspect)}.')

            best = None
            for _, m, toks in inspect:
                try:
                    books = run_json(['polymarket', 'clob', 'books', ','.join(toks), '-o', 'json'] + SIG)
                    if not isinstance(books, list) or len(books) < 2:
                        continue
                    a1, s1 = best_ask_from_book(books[0])
                    a2, s2 = best_ask_from_book(books[1])
                    if a1 is None or a2 is None:
                        continue
                    ask_sum = a1 + a2
                    min_size = min(s1 or 0, s2 or 0)
                    if best is None or ask_sum < best['ask_sum']:
                        best = {
                            'market_id': m.get('id'),
                            'question': m.get('question', ''),
                            'ask_sum': ask_sum,
                            'min_size': min_size,
                            'token_ids': toks,
                            'a1': a1,
                            'a2': a2,
                        }
                except Exception:
                    continue

            action_taken = False
            if best:
                max_size = MAX_RISK_USDC / max(best['ask_sum'], 0.0001)
                executable = best['ask_sum'] < 0.99 and best['min_size'] >= max_size
                cycle_lines.append(
                    f"Top book check: market {best['market_id']} ask_sum={best['ask_sum']:.4f}, est max_size@2USDC={max_size:.4f}, top depth min={best['min_size']:.4f}."
                )

                if hold_only:
                    cycle_lines.append('Decision: HOLD (HOLD-only mode active).')
                elif executable:
                    # Passive-only + capital-preservation policy: require very high confidence.
                    # In this safe-mode runner we still default to HOLD unless explicitly upgraded.
                    cycle_lines.append('Decision: HOLD (edge observed but not high-confidence under passive-only constraint).')
                else:
                    cycle_lines.append('Decision: HOLD (no executable high-confidence edge after book/depth check).')
            else:
                cycle_lines.append('Decision: HOLD (no candidate with usable two-sided books).')

            append_log(cycle_lines)
            error_streak = 0
            if action_taken:
                pass

        except Exception as e:
            error_streak += 1
            cycle_lines.append(f'Cycle error: {str(e).strip()}')
            cycle_lines.append(f'Error streak: {error_streak}.')
            if error_streak >= ERROR_BURST_THRESHOLD:
                cooldown_until = time.time() + COOLDOWN_SEC
                cycle_lines.append('Major state change: error burst detected; pausing scans for 30 minutes.')
                error_streak = 0
            cycle_lines.append('Decision: HOLD (error-safe fallback).')
            append_log(cycle_lines)

        time.sleep(CYCLE_SEC)

    append_log(['End-of-run summary: 24h scanner window completed.', 'No unsafe actions taken.'])


if __name__ == '__main__':
    with RUN_LOG.open('a') as run:
        run.write(f"\n[{ts()}] Starting safe_mode_24h_scanner.py\n")
    scanner()
