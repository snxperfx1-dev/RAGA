# Letra 37 — MQL5 Expert Advisor

A complete, autonomous MetaTrader 5 Expert Advisor ported from the
**"Letra 37"** Pine Script v6 market-physics / Smart-Money-Concepts engine
(`LETRA 37.txt`). It reproduces the original's full decision pipeline
bar-by-bar and adds production-grade order execution and risk management.

## What it does

The original indicator is a multi-engine wave-lifecycle model. The EA ports
every stage that drives a trade decision:

| Stage | Module | Pine section |
|------|--------|--------------|
| Core physics (velocity / acceleration / convexity / efficiency / displacement) on fixed M5 | `PhysicsEngine.mqh` | 2 |
| HTF belief engine + multi-timeframe bias | `BeliefEngine.mqh` | 3 |
| Fixed-TF structure engine (`f_se`) on M1/M3/M5/M15/H1/H4, fractal stack, **Engine 1A** phase authority | `StructureEngine.mqh` | f_se / 1A |
| Chart market structure (HH/HL/LH/LL, BOS/CHoCH, pivot memory, impulse, inducement finder) | `MarketStructure.mqh` | 4–8 |
| Physics observation scores + liquidity heatmap | `ObservationLiquidity.mqh` | 9, 10 |
| Geometry + wave intelligence (similarity model, beliefs, convexity maturity, wave progress, prediction, adaptive confidence) | `GeometryWave.mqh` | 11, 12 |
| Wave spawn + recursive entry cycles + induction classification | `WaveSpawn.mqh` | 13, 14 |
| Energy Resolution Framework (EDE/RE/EAE) + **entry gate**; advisory FU/FRZ | `Erf.mqh` | ERF, 17/18 |
| Scoring, Bayesian probability, opportunity / net-edge, HTF gate, execution lock, entry signals, trade-state | `ScoringSignals.mqh` | 15–24 |
| Order execution + risk management | `TradeManager.mqh` | (new) |
| On-chart status panel | `Dashboard.mqh` | (new) |

`PineRuntime.mqh` provides the Pine→MQL5 primitives (`na`/`nz`, history
buffers, `ta.ema`/`ta.rma`/`ta.sma`, pivots). `Context.mqh` + `SharedState.mqh`
hold shared state; `Pipeline.mqh` orchestrates the per-bar evaluation in the
exact top-to-bottom order of the source script.

## Entry logic (faithful to source)

A long fires when **all** of these hold (short is symmetric):
`direction==+1`, Engine-1A phase is **Demand Return**, demand-return belief > 50,
expansion belief < 60, absorption belief > 25, HTF aligned, setup grade passes,
not locked, net-edge filter passes, pre-convexity & induction evidence present,
structure OK, liquidity sweep OK, order block fresh, and the ERF readiness gate is open.

Exits follow the source trade-state engine (opposite BOS, convexity-shift with
fading energy, opposing HTF, stale OB, invalidation, Absorption/Retracement phase).

## Risk management (added for autonomous trading)

- Risk-% position sizing from the stop distance (or fixed lots)
- Structural (flip-zone / invalidation) or ATR stop loss; ATR take-profit
- ATR trailing stop + breakeven
- Spread filter, session/day filter, max-positions cap
- Daily-loss limit and total-drawdown circuit breakers

## Installation

1. Copy `Letra37EA.mq5` to `MQL5/Experts/` and the `Include/Letra37/` folder to
   `MQL5/Include/Letra37/` (or keep the relative `Include/Letra37/` layout next
   to the `.mq5`).
2. Open `Letra37EA.mq5` in MetaEditor and **Compile** (F7).
3. Attach to a chart. The engine anchors its physics/structure on fixed
   timeframes (M5 + M1/M3/M15/H1/H4), so it behaves the same regardless of the
   chart timeframe; set the working timeframe via `InpWorkTF` (default M5).

## Important notes

- **Compile in MetaEditor.** This port was authored without an MQL5 compiler in
  the build environment; please compile and run a Strategy-Tester pass before
  any live use, and report any compiler messages.
- **Validate before live trading.** Always backtest/forward-test on a demo
  account first. Defaults are conservative (0.5% risk, 1 position). No strategy
  is guaranteed profitable; trade at your own risk.
- FU order blocks and FRZ are **advisory** (surfaced for the dashboard) and do
  not gate entries — matching the source, where their inputs are not wired into
  the entry decision.
- Visual-only elements of the original (boxes, labels, the `liqg` display
  overlay) are intentionally not reproduced; they never affected trade signals.
