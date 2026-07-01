# Dual HMA Trend-Following EA Project (MT5)

This project implements a Hull Moving Average (HMA) based trend-following system for MetaTrader 5: a custom indicator that plots two HMA lines, and a series of Expert Advisors (EAs) that trade off those lines — from a bare-bones diagnostic version up to a full-featured EA with an entry-angle filter, a trade delay, and a trading-session filter.

MT5 has no built-in HMA indicator, so the HMA math (SMA/EMA/SMMA/LWMA-based) is implemented from scratch and shared between the indicator and every EA via `iCustom()`.

## Core concept

- **Fast HMA** (short period, ~12–25): reacts quickly, represents the current short-term move.
- **Slow HMA** (long period, ~60–120): reacts slowly, represents the underlying trend.
- **Trend** of each line = its **tangent (slope)**: is the current value higher or lower than the previous bar's value?
- **Trade logic (current, final version):** open a position only when both HMAs trend the **same** direction (both up → Buy, both down → Sell); close immediately once they **diverge** (disagree).

## Files, in the order they were built

| File | Type | Purpose |
|---|---|---|
| `HMA_Dual.mq5` | Indicator | Calculates and plots both HMA lines on the chart. Each line is color-coded (blue = rising, red = falling). Every EA below loads this via `iCustom()` both to display the lines and to read their values for trading decisions — so what you see on the chart is always exactly what the EA is trading on. |
| `HMA_Test_EA.mq5` | Diagnostic EA | Bare-minimum EA used to confirm the core mechanism (reading the indicator + placing real orders) works, with no filters of any kind. Opens on HMA divergence, wide fixed SL/TP, prints every bar. Not intended as a real strategy — kept for reference/debugging. |
| `HMA_Trend_EA.mq5` | Full-featured EA | The original, most heavily-filtered version: trend-confirmation window, a cooldown period (in bars), a minimum HMA-separation filter, spread filter, ATR or fixed SL/TP, reverse-on-flip logic. More configurable but more complex. |
| `HMA_TrendHold_EA.mq5` | Simplified EA | Stripped down to the essential rule with no extra filters: open when both HMAs agree, close when they diverge, optional toggle to disable auto-close entirely (SL/TP-only exit). |
| `HMA_TrendHold_Angle_EA.mq5` | Simplified EA + angle filter | Adds a minimum slope-angle requirement on the fast HMA before opening (filters out shallow/weak moves), plus a minimum time delay (in minutes) after a close before a new trade can open. |
| `HMA_TrendHold_Angle_Session_EA.mq5` | **Current/most complete** | Everything in the Angle EA, plus a trading-session filter: Asian, Europe-only, Europe+New York overlap, New York-only, or Full Time (24h). Both opening and closing are restricted to the selected session window. |

**If you're not sure which EA to use:** `HMA_TrendHold_Angle_Session_EA.mq5` is the most complete and current version, and includes everything from the simpler ones as optional, disableable features (set the angle threshold to 0, delay to 0, and session to Full Time to make it behave like the plain `HMA_TrendHold_EA.mq5`).

## Installation

1. Copy `HMA_Dual.mq5` into `MQL5\Indicators\` and compile it in MetaEditor (F7). This must be done first — the EAs load it by name.
2. Copy whichever EA(s) you want into `MQL5\Experts\` and compile.
3. Attach the EA to a chart, or run it in the Strategy Tester. If the EA's `InpShowHMAOnChart` input is `true` (default), it will automatically attach `HMA_Dual` to the chart for you — no need to drag the indicator on separately.

**Important:** the EA and the indicator both take Fast/Slow period, method, and applied-price inputs. The EA passes its own values into the indicator when it loads it via `iCustom()`, so configuring the EA's inputs is enough — you don't need to separately configure the indicator if it's only being displayed because the EA attached it.

## Key input groups (HMA_TrendHold_Angle_Session_EA.mq5)

- **HMA Settings** — fast/slow period, averaging method, applied price, timeframe, whether to show the lines on chart.
- **Angle Filter** — `InpMinFastAngleDegrees`: the fast HMA's per-bar slope (converted to an angle via `arctan(points-per-bar)`) must exceed this before opening. This angle is **not** a real geometric angle — it depends on the instrument's point size, so a value tuned for gold will not mean the same thing on a forex pair. Tune it per instrument using the Journal's `angle=...` diagnostic output. Set to `0` to disable.
- **Trade Delay** — `InpDelayMinutes`: minimum wall-clock minutes after a close before a new trade can open. Set to `0` to disable.
- **Trading Session** — `InpTradingSession` (Asian / Europe only / Europe+NY overlap / New York only / Full Time) and `InpBrokerGMTOffsetHours`. Session windows are defined in UTC; since your broker's server time is almost never UTC, you must set the GMT offset correctly (check your broker's account/server info — this commonly shifts by an hour with daylight saving time, so re-check seasonally).
- **Exit Behavior** — `InpEnableAutoClose` (toggle the divergence-close behavior off if you want SL/TP to be the only exit), `InpSignalOnCurrentBar` (react on the live forming bar every tick vs. wait for the bar to close — closed-bar is the default and safer choice, since it guarantees the EA only trades on the same finalized values shown by the chart's line colors).
- **Trade Settings** — lot size, magic number, slippage.
- **Stop Loss / Take Profit** — fixed points or ATR-based, with **automatic widening** if your value is tighter than the broker's minimum stop distance (this was a real issue encountered on gold, where a 2-3 point stop is often too tight — the EA now auto-corrects and logs when it does).
- **Notifications** — popup alerts and verbose per-bar diagnostic logging (`InpVerboseLogging`, on by default) — recommended to keep on while tuning, since it prints the fast/slow trend values, angle, session status, and the reason any entry/exit was skipped.

## Debugging notes / lessons learned building this

A few non-obvious issues came up during development, in case you extend this further:

- **Performance:** the indicator recomputes each HMA using the standard `prev_calculated` incremental pattern — each historical bar is calculated once and cached, not recomputed on every tick. Without this, backtests over long date ranges become extremely slow (effectively O(bars²)).
- **Spread filters using raw "points" are fragile across instruments.** A threshold tuned for a 5-digit forex pair can be meaningless (either far too loose or far too tight) for gold or an index, since point size varies wildly. If you add a spread filter back in, default it off and tune it per-symbol.
- **Broker minimum stop distance (`SYMBOL_TRADE_STOPS_LEVEL` / `SYMBOL_TRADE_FREEZE_LEVEL`)** can silently reject orders if your SL/TP is too tight — especially on gold. The EA now reads this from the broker and auto-widens if needed.
- **Live/forming-bar signals vs. chart colors:** reacting on the still-forming bar (`InpSignalOnCurrentBar=true`) means the EA can act on a momentary intrabar wiggle that doesn't match the bar's eventual closed (and colored) direction. Default is closed-bar evaluation to avoid this mismatch.

## Disclaimer

This is a working implementation of the trading logic as specified, not a validated profitable strategy. Before running any of this on a live account:

1. Compile and clear all warnings in MetaEditor.
2. Backtest in the Strategy Tester across a meaningful date range and multiple market conditions.
3. Run on a demo account for a period of time.
4. Understand that HMA crossover/agreement systems are trend-following and will underperform in ranging/choppy markets — tune periods, angle threshold, and session filter to your instrument accordingly.