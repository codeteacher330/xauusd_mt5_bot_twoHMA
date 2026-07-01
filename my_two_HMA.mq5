//+------------------------------------------------------------------+
//|                                              HMA_Trend_EA.mq5     |
//|  Dual Hull Moving Average trend-following Expert Advisor         |
//|                                                                    |
//|  Requires HMA_Dual.mq5 to be compiled and present in your         |
//|  MQL5\Indicators folder - the EA attaches it to the chart so      |
//|  you can SEE both HMA lines, and reads its buffers to trade.      |
//|                                                                    |
//|  Logic:                                                            |
//|   - Fast HMA (short period, e.g. 12-25) = current move direction   |
//|   - Slow HMA (long period, e.g. 60-120) = underlying trend         |
//|   - Trend of each HMA = slope (tangent) = HMA[now] - HMA[prev]     |
//|   - Enter (Buy/Sell) when BOTH HMAs point the same direction       |
//|   - Flatten / stand aside when the two HMAs disagree               |
//|   - SL/TP set automatically on entry (fixed points or ATR based)   |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version "1.10"
#property strict

#include <Trade\Trade.mqh>

//====================================================================
// INPUTS  (Control Panel)
//====================================================================

//----- HMA settings -----
input group "===== HMA Settings =====" input int InpFastHMAPeriod = 21; // Fast HMA period (recommended 12-25)
input int InpSlowHMAPeriod = 89;                                        // Slow HMA period (recommended 60-120)
input ENUM_MA_METHOD InpHMAMethod = MODE_LWMA;                          // HMA averaging method (internal MA type)
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;                 // Applied price
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT;                    // Timeframe used for HMA calculation
input bool InpSignalOnCurrentBar = false;                               // Evaluate signal on current (unclosed) bar
input bool InpShowHMAOnChart = true;                                    // Attach HMA_Dual indicator lines to chart

//----- Trade settings -----
input group "===== Trade Settings =====" input double InpLotSize = 0.10; // Fixed lot size (used if money management is off)
input bool InpUseMoneyManagement = false;                                // Use % risk based position sizing
input double InpRiskPercent = 1.0;                                       // Risk % of balance per trade (if MM enabled)
input long InpMagicNumber = 202601;                                      // Magic number
input int InpSlippagePoints = 10;                                        // Max slippage (points)
input double InpMaxSpreadPoints = 0;                                     // Max allowed spread (points), 0 = no filter (recommended default - tune per instrument)
input bool InpAllowReverse = true;                                       // Close & reverse position when signal flips
input bool InpCloseOnTrendConflict = true;                               // Close position when the two HMAs disagree

//----- Overtrading filters -----
input group "===== Overtrading Filters =====" input int InpTrendConfirmBars = 3; // Bars of lookback for net trend direction (1 = react instantly, bar-to-bar)
input int InpCooldownBars = 5;                                                   // Minimum bars to wait after a close before opening again
input double InpMinHMASeparationPoints = 0;                                      // Minimum distance between fast & slow HMA (points), 0 = disabled

//----- Stop Loss / Take Profit -----
input group "===== Stop Loss / Take Profit =====" enum ENUM_SLTP_MODE {
    SLTP_FIXED_POINTS = 0, // Fixed points
    SLTP_ATR = 1           // ATR based
};
input ENUM_SLTP_MODE InpSLTPMode = SLTP_FIXED_POINTS; // SL/TP calculation mode
input int InpStopLossPoints = 1000;                   // Stop Loss (points) - fixed mode (auto-widened if too tight for your broker)
input int InpTakeProfitPoints = 2000;                 // Take Profit (points) - fixed mode (auto-widened if too tight for your broker)
input int InpATRPeriod = 14;                          // ATR period - ATR mode
input double InpATR_SL_Mult = 2.0;                    // ATR multiplier for SL
input double InpATR_TP_Mult = 4.0;                    // ATR multiplier for TP

//----- Trailing stop -----
input group "===== Trailing Stop =====" input bool InpUseTrailingStop = false; // Enable trailing stop
input int InpTrailingStopPoints = 200;                                         // Trailing stop distance (points)
input int InpTrailingStepPoints = 50;                                          // Trailing step (points)

//----- Notifications -----
input group "===== Notifications =====" input bool InpEnableAlert = true; // Popup alert on signal
input bool InpEnableEmail = false;                                        // Send email on signal
input bool InpEnablePush = false;                                         // Send push notification on signal
input bool InpVerboseLogging = true;                                      // Print trend/filter diagnostics to Experts log each bar

//====================================================================
// GLOBALS
//====================================================================
CTrade trade;
int g_atrHandle = INVALID_HANDLE;
int g_hmaHandle = INVALID_HANDLE; // handle to HMA_Dual custom indicator
datetime g_lastBarTime = 0;
long g_barCounter = 0;                 // increments once per new bar
long g_lastCloseBarCounter = -1000000; // bar counter value at last position close

// HMA_Dual buffer layout: 0=fast value, 1=fast color, 2=slow value, 3=slow color
#define HMA_BUF_FAST 0
#define HMA_BUF_SLOW 2

//====================================================================
// SIGNAL: read trend directly from the HMA_Dual indicator's buffers
//====================================================================
// shiftBars = 0 -> use current (still forming) bar as the latest point
// shiftBars = 1 -> use the last CLOSED bar as the latest point
// Confirmation checks NET direction over the last 'confirmBars' bars
// (latest value vs. the value confirmBars bars earlier) rather than
// requiring every single intervening bar to step the same way - HMA lines
// (especially the fast one) often wiggle slightly bar-to-bar even inside
// a clear trend, so a strict monotonic requirement was choking off
// almost every signal.
bool GetHMATrend(int bufferIndex, int shiftBars, int confirmBars, int& trendOut) {
    int count = confirmBars + 1;
    double buf[];
    ArraySetAsSeries(buf, true);
    if (CopyBuffer(g_hmaHandle, bufferIndex, shiftBars, count, buf) < count)
        return false;

    double newest = buf[0];
    double oldest = buf[confirmBars];

    if (newest > oldest)
        trendOut = 1;
    else if (newest < oldest)
        trendOut = -1;
    else
        trendOut = 0;
    return true;
}

bool GetHMAValue(int bufferIndex, int shiftBars, double& valOut) {
    double buf[];
    ArraySetAsSeries(buf, true);
    if (CopyBuffer(g_hmaHandle, bufferIndex, shiftBars, 1, buf) < 1)
        return false;
    valOut = buf[0];
    return true;
}

//====================================================================
// POSITION HELPERS
//====================================================================
bool HasOpenPosition(ENUM_POSITION_TYPE& type, double& volume, ulong& ticket) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong tk = PositionGetTicket(i);
        if (tk == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if ((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        volume = PositionGetDouble(POSITION_VOLUME);
        ticket = tk;
        return true;
    }
    return false;
}

void CloseAllPositions() {
    ENUM_POSITION_TYPE type;
    double vol;
    ulong ticket;
    bool closedAny = false;
    while (HasOpenPosition(type, vol, ticket)) {
        trade.PositionClose(ticket, (ulong)InpSlippagePoints);
        closedAny = true;
    }
    if (closedAny)
        g_lastCloseBarCounter = g_barCounter;
}

double GetATR() {
    double buf[];
    ArraySetAsSeries(buf, true);
    if (CopyBuffer(g_atrHandle, 0, 0, 1, buf) < 1)
        return 0.0;
    return buf[0];
}

double NormalizeLot(double lots) {
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (step <= 0)
        step = 0.01;
    double norm = MathRound(lots / step) * step;
    norm = MathMax(minLot, MathMin(maxLot, norm));
    return norm;
}

double CalcLotSize(double slDistancePoints) {
    if (!InpUseMoneyManagement)
        return NormalizeLot(InpLotSize);

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskMoney = balance * InpRiskPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    if (tickSize <= 0 || tickValue <= 0 || slDistancePoints <= 0)
        return NormalizeLot(InpLotSize);

    double slPriceDist = slDistancePoints * point;
    double lossPerLot = (slPriceDist / tickSize) * tickValue;
    if (lossPerLot <= 0)
        return NormalizeLot(InpLotSize);

    double lots = riskMoney / lossPerLot;
    return NormalizeLot(lots);
}

bool SpreadOK() {
    if (InpMaxSpreadPoints <= 0)
        return true;
    double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    return spread <= InpMaxSpreadPoints;
}

void Notify(const string msg) {
    if (InpEnableAlert)
        Alert(msg);
    if (InpEnableEmail)
        SendMail("HMA_Trend_EA signal", msg);
    if (InpEnablePush)
        SendNotification(msg);
    Print(msg);
}

//====================================================================
// TRADE EXECUTION
//====================================================================
void OpenPosition(bool isBuy) {
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double slDistPoints = 0, tpDistPoints = 0;

    if (InpSLTPMode == SLTP_FIXED_POINTS) {
        slDistPoints = InpStopLossPoints;
        tpDistPoints = InpTakeProfitPoints;
    } else // ATR based
    {
        double atr = GetATR();
        if (atr <= 0)
            return;
        slDistPoints = (atr * InpATR_SL_Mult) / point;
        tpDistPoints = (atr * InpATR_TP_Mult) / point;
    }

    // Safety net: brokers reject SL/TP placed closer than their minimum
    // stops/freeze level (this varies wildly by instrument - gold, indices
    // and low-priced forex pairs all use very different point scales).
    // Auto-widen anything too tight instead of letting the order silently
    // fail with "Invalid stops".
    long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
    long minLevel = MathMax(stopsLevel, freezeLevel);
    long safeMin = minLevel + 10; // small buffer above the broker's own minimum

    if (minLevel > 0 && slDistPoints < safeMin) {
        if (InpVerboseLogging)
            Print(StringFormat("HMA_Trend_EA: SL distance %.1f pts too tight for broker min %ld pts - widened to %ld pts.",
                               slDistPoints, minLevel, safeMin));
        slDistPoints = (double)safeMin;
    }
    if (minLevel > 0 && tpDistPoints < safeMin) {
        if (InpVerboseLogging)
            Print(StringFormat("HMA_Trend_EA: TP distance %.1f pts too tight for broker min %ld pts - widened to %ld pts.",
                               tpDistPoints, minLevel, safeMin));
        tpDistPoints = (double)safeMin;
    }

    double sl = isBuy ? price - slDistPoints * point : price + slDistPoints * point;
    double tp = isBuy ? price + tpDistPoints * point : price - tpDistPoints * point;

    double lots = CalcLotSize(slDistPoints);
    trade.SetDeviationInPoints((ulong)InpSlippagePoints);
    trade.SetExpertMagicNumber(InpMagicNumber);

    bool ok = isBuy ? trade.Buy(lots, _Symbol, price, sl, tp, "HMA_Trend_EA")
                    : trade.Sell(lots, _Symbol, price, sl, tp, "HMA_Trend_EA");

    uint retcode = trade.ResultRetcode();
    if (!ok || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL)) {
        Notify(StringFormat("HMA_Trend_EA: %s order FAILED. Retcode=%u (%s). Lots=%.2f SL=%.5f TP=%.5f",
                            isBuy ? "BUY" : "SELL", retcode, trade.ResultRetcodeDescription(), lots, sl, tp));
        return;
    }

    Notify(StringFormat("HMA_Trend_EA: %s opened. Lots=%.2f SL=%.5f TP=%.5f",
                        isBuy ? "BUY" : "SELL", lots, sl, tp));
}

void ManageTrailingStop() {
    if (!InpUseTrailingStop)
        return;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong tk = PositionGetTicket(i);
        if (tk == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if ((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;

        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double curSL = PositionGetDouble(POSITION_SL);
        double curTP = PositionGetDouble(POSITION_TP);

        if (type == POSITION_TYPE_BUY) {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double newSL = bid - InpTrailingStopPoints * point;
            if (bid - openPrice > InpTrailingStopPoints * point &&
                (curSL == 0 || newSL - curSL > InpTrailingStepPoints * point))
                trade.PositionModify(tk, newSL, curTP);
        } else if (type == POSITION_TYPE_SELL) {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double newSL = ask + InpTrailingStopPoints * point;
            if (openPrice - ask > InpTrailingStopPoints * point &&
                (curSL == 0 || curSL - newSL > InpTrailingStepPoints * point))
                trade.PositionModify(tk, newSL, curTP);
        }
    }
}

//====================================================================
// EXPERT EVENTS
//====================================================================
int OnInit() {
    if (InpSLTPMode == SLTP_ATR) {
        g_atrHandle = iATR(_Symbol, InpTimeframe, InpATRPeriod);
        if (g_atrHandle == INVALID_HANDLE) {
            Print("Failed to create ATR handle");
            return (INIT_FAILED);
        }
    }

    // Load the HMA_Dual custom indicator - it does the actual HMA math and
    // plots the two lines; the EA just reads its buffers for signals.
    g_hmaHandle = iCustom(_Symbol, InpTimeframe, "HMA_Dual",
                          InpFastHMAPeriod, InpSlowHMAPeriod,
                          InpHMAMethod, InpAppliedPrice);
    if (g_hmaHandle == INVALID_HANDLE) {
        Print("Failed to load HMA_Dual indicator. Make sure HMA_Dual.mq5 is "
              "compiled and placed in your MQL5\\Indicators folder.");
        return (INIT_FAILED);
    }

    if (InpShowHMAOnChart)
        ChartIndicatorAdd(0, 0, g_hmaHandle);

    trade.SetTypeFillingBySymbol(_Symbol);
    Print("HMA_Trend_EA initialized. Fast=", InpFastHMAPeriod, " Slow=", InpSlowHMAPeriod);
    return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    if (g_atrHandle != INVALID_HANDLE)
        IndicatorRelease(g_atrHandle);
    if (g_hmaHandle != INVALID_HANDLE)
        IndicatorRelease(g_hmaHandle);
}

void OnTick() {
    ManageTrailingStop();

    datetime curBarTime = iTime(_Symbol, InpTimeframe, 0);
    bool isNewBar = (curBarTime != g_lastBarTime);
    if (isNewBar) {
        g_lastBarTime = curBarTime;
        g_barCounter++;
    }
    if (!InpSignalOnCurrentBar && !isNewBar)
        return;

    if (!SpreadOK()) {
        if (InpVerboseLogging) {
            double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            Print(StringFormat("HMA_Trend_EA: skipped - spread %.1f pts exceeds max %.1f pts.",
                               spreadPts, InpMaxSpreadPoints));
        }
        return;
    }

    int shift = InpSignalOnCurrentBar ? 0 : 1;
    int confirmBars = MathMax(1, InpTrendConfirmBars);

    int fastTrend = 0, slowTrend = 0;
    if (!GetHMATrend(HMA_BUF_FAST, shift, confirmBars, fastTrend)) {
        if (InpVerboseLogging)
            Print("HMA_Trend_EA: not enough bar history yet for fast HMA trend.");
        return;
    }
    if (!GetHMATrend(HMA_BUF_SLOW, shift, confirmBars, slowTrend)) {
        if (InpVerboseLogging)
            Print("HMA_Trend_EA: not enough bar history yet for slow HMA trend.");
        return;
    }

    ENUM_POSITION_TYPE posType;
    double posVol;
    ulong posTicket;
    bool hasPos = HasOpenPosition(posType, posVol, posTicket);

    bool sameTrend = (fastTrend != 0 && fastTrend == slowTrend);

    if (InpVerboseLogging)
        Print(StringFormat("HMA_Trend_EA: bar=%d fastTrend=%d slowTrend=%d sameTrend=%s hasPos=%s cooldownLeft=%d",
                           (int)g_barCounter, fastTrend, slowTrend, sameTrend ? "true" : "false", hasPos ? "true" : "false",
                           (int)MathMax(0, InpCooldownBars - (g_barCounter - g_lastCloseBarCounter))));

    if (sameTrend) {
        bool wantBuy = (fastTrend > 0);

        if (!hasPos) {
            // Cooldown: don't re-enter too soon after the last close
            if (g_barCounter - g_lastCloseBarCounter < InpCooldownBars) {
                if (InpVerboseLogging)
                    Print("HMA_Trend_EA: entry skipped - cooldown active.");
                return;
            }

            // Separation filter: skip entries when the lines are too close
            // together (choppy/flat market, high whipsaw risk)
            if (InpMinHMASeparationPoints > 0) {
                double fastVal = 0, slowVal = 0;
                if (!GetHMAValue(HMA_BUF_FAST, shift, fastVal))
                    return;
                if (!GetHMAValue(HMA_BUF_SLOW, shift, slowVal))
                    return;
                double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
                double sepPoints = MathAbs(fastVal - slowVal) / point;
                if (sepPoints < InpMinHMASeparationPoints) {
                    if (InpVerboseLogging)
                        Print(StringFormat("HMA_Trend_EA: entry skipped - HMA separation %.1f pts < min %.1f pts.",
                                           sepPoints, InpMinHMASeparationPoints));
                    return;
                }
            }

            OpenPosition(wantBuy);
        } else {
            bool posIsBuy = (posType == POSITION_TYPE_BUY);
            if (posIsBuy != wantBuy && InpAllowReverse) {
                // A reversal is a deliberate, immediate flip - cooldown should
                // not re-block it right after we just closed to make room for it.
                CloseAllPositions();
                OpenPosition(wantBuy);
            }
        }
    } else {
        if (InpCloseOnTrendConflict && hasPos) {
            CloseAllPositions();
            Notify("HMA_Trend_EA: HMAs diverged, position closed (standing aside).");
        }
    }
}
//+------------------------------------------------------------------+