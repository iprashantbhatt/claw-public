#!/usr/bin/env node
import { execSync } from 'node:child_process';

const CFG = {
  token: process.env.PM_TOKEN || '', // required
  side: (process.env.PM_SIDE || 'buy').toLowerCase(), // buy|sell
  amountUsdc: Number(process.env.PM_AMOUNT_USDC || 2),
  signatureType: process.env.PM_SIG || 'eoa',
  dryRun: (process.env.DRY_RUN || 'true').toLowerCase() !== 'false',
  pollMs: Number(process.env.POLL_MS || 600),
  momentumWindowMs: Number(process.env.MOMENTUM_WINDOW_MS || 10000),
  triggerPct: Number(process.env.TRIGGER_PCT || 0.20), // Binance move % over window
  mismatchPct: Number(process.env.MISMATCH_PCT || 1.5), // move - poly implied mismatch
  cooldownMs: Number(process.env.COOLDOWN_MS || 300000),
  maxTrades: Number(process.env.MAX_TRADES || 10),
  maxLossUsdc: Number(process.env.MAX_LOSS_USDC || 8),
};

if (!CFG.token) {
  console.error('Missing PM_TOKEN. Example: export PM_TOKEN=0x...');
  process.exit(1);
}

let trades = 0;
let lastTradeAt = 0;
let startBal = null;
const ticks = []; // {t,p}

function sh(cmd) {
  return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function getBalance() {
  const out = sh(`~/.local/bin/polymarket clob balance --asset-type collateral --signature-type ${CFG.signatureType} -o json`);
  const j = JSON.parse(out);
  return Number(j.balance || 0);
}

function getPolyMid() {
  const out = sh(`~/.local/bin/polymarket clob midpoint ${CFG.token} --signature-type ${CFG.signatureType} -o json`);
  const j = JSON.parse(out);
  return Number(j.midpoint || 0);
}

function placeOrder() {
  const cmd = `~/.local/bin/polymarket clob market-order --token ${CFG.token} --side ${CFG.side} --amount ${CFG.amountUsdc} --signature-type ${CFG.signatureType} -o json`;
  if (CFG.dryRun) {
    console.log(`[DRY_RUN] ${cmd}`);
    return { success: true, dryRun: true };
  }
  const out = sh(cmd);
  return JSON.parse(out);
}

function pct(a, b) {
  if (!a) return 0;
  return ((b - a) / a) * 100;
}

function onTick(price) {
  const now = Date.now();
  ticks.push({ t: now, p: price });
  while (ticks.length && now - ticks[0].t > CFG.momentumWindowMs) ticks.shift();
}

async function loop() {
  try {
    const bal = getBalance();
    if (startBal === null) startBal = bal;
    const dd = startBal - bal;
    if (dd > CFG.maxLossUsdc) {
      console.log(`STOP drawdown guard hit: start=${startBal} bal=${bal} dd=${dd}`);
      process.exit(0);
    }

    if (ticks.length < 2) return;

    const first = ticks[0].p;
    const last = ticks[ticks.length - 1].p;
    const move = pct(first, last); // Binance move % window

    const mid = getPolyMid();
    const implied = (mid - 0.5) * 2 * 100; // rough % from midpoint around 0.5
    const mismatch = Math.abs(move - implied);

    const now = Date.now();
    const canTrade = (now - lastTradeAt) > CFG.cooldownMs && trades < CFG.maxTrades;

    console.log(`${new Date().toISOString()} binMove=${move.toFixed(3)}% polyMid=${mid.toFixed(3)} implied=${implied.toFixed(3)} mismatch=${mismatch.toFixed(3)} bal=${bal}`);

    if (canTrade && Math.abs(move) >= CFG.triggerPct && mismatch >= CFG.mismatchPct) {
      const res = placeOrder();
      trades += 1;
      lastTradeAt = now;
      console.log(`TRADE #${trades}:`, res);
    }
  } catch (e) {
    console.error('loop error:', e.message || String(e));
  }
}

const ws = new WebSocket('wss://stream.binance.com:9443/ws/btcusdt@trade');
ws.onopen = () => console.log('Connected Binance BTCUSDT trade stream');
ws.onmessage = (ev) => {
  try {
    const d = JSON.parse(ev.data);
    const p = Number(d.p);
    if (Number.isFinite(p)) onTick(p);
  } catch {}
};
ws.onerror = (e) => console.error('ws error', e?.message || e);
ws.onclose = () => console.log('ws closed');

setInterval(loop, CFG.pollMs);
console.log('Latency bot started with config:', CFG);
