//+------------------------------------------------------------------+
//|                                              HMA_Test_EA.mq5      |
//|  STRIPPED-DOWN DIAGNOSTIC EA - not a real trading strategy.       |
//|                                                                    |
//|  Purpose: isolate whether basic trade placement works at all,     |
//|  with none of the filters (cooldown, confirmation, spread check,  |
//|  ATR mode, reverse logic) that might be silently blocking trades  |
//|  in the full HMA_Trend_EA.                                        |
//|                                                                    |
//|  Rule: each new bar, compute the tangent (slope) of the fast and  |
//|  slow HMA (current value minus previous bar's value). If the two  |
//|  slopes point in DIFFERENT directions and there is no open        |
//|  position, open one (direction = fast HMA's slope). That's it.    |
//|                                                                    |
//|  Requires HMA_Dual.mq5 compiled and present in MQL5\Indicators.   |
//+------------------------------------------------------------------+
#property copyright "Diagnostic EA"
#property version "1.00"
#property strict

#include <Trade\Trade.mqh>

input int InpFastHMAPeriod = 21;                        // Fast HMA period
input int InpSlowHMAPeriod = 89;                        // Slow HMA period
input ENUM_MA_METHOD InpHMAMethod = MODE_LWMA;          // HMA averaging method
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // Applied price
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT;    // Timeframe

input double InpLotSize = 0.10;        // Fixed lot size
input long InpMagicNumber = 999001;    // Magic number
input int InpSlippagePoints = 50;      // Slippage (points)
input int InpStopLossPoints = 5000;    // Wide fixed SL (points) - generous on purpose
input int InpTakeProfitPoints = 10000; // Wide fixed TP (points) - generous on purpose

CTrade trade;
int g_hmaHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;

#define HMA_BUF_FAST 0
#define HMA_BUF_SLOW 2

int OnInit() {
    g_hmaHandle = iCustom(_Symbol, InpTimeframe, "HMA_Dual",
                          InpFastHMAPeriod, InpSlowHMAPeriod,
                          InpHMAMethod, InpAppliedPrice);
    if (g_hmaHandle == INVALID_HANDLE) {
        Print("HMA_Test_EA: FAILED to load HMA_Dual indicator. Check it is compiled ",
              "and sitting in MQL5\\Indicators\\.");
        return (INIT_FAILED);
    }
    ChartIndicatorAdd(0, 0, g_hmaHandle);
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints((ulong)InpSlippagePoints);
    Print("HMA_Test_EA: initialized OK. Fast=", InpFastHMAPeriod, " Slow=", InpSlowHMAPeriod);
    return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    if (g_hmaHandle != INVALID_HANDLE)
        IndicatorRelease(g_hmaHandle);
}

bool GetSlope(int bufferIndex, int& slopeSign, double& val0, double& val1) {
    double buf[];
    ArraySetAsSeries(buf, true);
    if (CopyBuffer(g_hmaHandle, bufferIndex, 1, 2, buf) < 2) // shift=1: last CLOSED bar vs the one before it
        return false;
    val0 = buf[0];
    val1 = buf[1];
    if (val0 > val1)
        slopeSign = 1;
    else if (val0 < val1)
        slopeSign = -1;
    else
        slopeSign = 0;
    return true;
}

bool HasOpenPosition() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong tk = PositionGetTicket(i);
        if (tk == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if ((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        return true;
    }
    return false;
}

void OnTick() {
    datetime curBarTime = iTime(_Symbol, InpTimeframe, 0);
    if (curBarTime == g_lastBarTime)
        return; // only act once per new bar
    g_lastBarTime = curBarTime;

    int fastSlope = 0, slowSlope = 0;
    double fv0, fv1, sv0, sv1;

    if (!GetSlope(HMA_BUF_FAST, fastSlope, fv0, fv1)) {
        Print("HMA_Test_EA: not enough history yet for fast HMA.");
        return;
    }
    if (!GetSlope(HMA_BUF_SLOW, slowSlope, sv0, sv1)) {
        Print("HMA_Test_EA: not enough history yet for slow HMA.");
        return;
    }

    Print(StringFormat("HMA_Test_EA: fast(%.5f->%.5f)=%d  slow(%.5f->%.5f)=%d  hasPos=%s",
                       fv1, fv0, fastSlope, sv1, sv0, slowSlope, HasOpenPosition() ? "true" : "false"));

    if (fastSlope == slowSlope)
        return; // same direction -> do nothing (this test only fires on DIVERGENCE)
    if (fastSlope == 0 || slowSlope == 0)
        return; // flat line -> ambiguous, skip
    if (HasOpenPosition())
        return; // only one position at a time for this test

    bool isBuy = (fastSlope > 0);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = isBuy ? price - InpStopLossPoints * point : price + InpStopLossPoints * point;
    double tp = isBuy ? price + InpTakeProfitPoints * point : price - InpTakeProfitPoints * point;

    bool ok = isBuy ? trade.Buy(InpLotSize, _Symbol, price, sl, tp, "HMA_Test_EA")
                    : trade.Sell(InpLotSize, _Symbol, price, sl, tp, "HMA_Test_EA");

    uint retcode = trade.ResultRetcode();
    Print(StringFormat("HMA_Test_EA: %s attempt. ok=%s retcode=%u (%s) price=%.5f sl=%.5f tp=%.5f",
                       isBuy ? "BUY" : "SELL", ok ? "true" : "false", retcode, trade.ResultRetcodeDescription(), price, sl, tp));
}
//+------------------------------------------------------------------+