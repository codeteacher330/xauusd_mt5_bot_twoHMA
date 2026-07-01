//+------------------------------------------------------------------+
//|                                                   HMA_Dual.mq5    |
//|  Plots two Hull Moving Averages on the chart.                    |
//|  Each line changes color when its own direction (slope) flips,   |
//|  matching the described "color changes on direction change"      |
//|  behavior. Used both for visualization and as the signal engine  |
//|  consumed by HMA_Trend_EA.mq5 via iCustom().                     |
//|                                                                    |
//|  PERFORMANCE NOTE: calculation is incremental. Each historical    |
//|  bar's HMA value is computed once and cached in persistent        |
//|  buffers; only the newest bar(s) are recomputed on each tick.     |
//|  This is essential for reasonable Strategy Tester speed - a full  |
//|  history recompute every tick would make long backtests crawl.   |
//+------------------------------------------------------------------+
#property copyright "Custom Indicator"
#property version "1.10"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots 2

//--- Fast HMA (plot 0)
#property indicator_label1 "Fast HMA"
#property indicator_type1 DRAW_COLOR_LINE
#property indicator_color1 clrDodgerBlue, clrRed
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

//--- Slow HMA (plot 1)
#property indicator_label2 "Slow HMA"
#property indicator_type2 DRAW_COLOR_LINE
#property indicator_color2 clrDodgerBlue, clrRed
#property indicator_style2 STYLE_SOLID
#property indicator_width2 3

//----- Inputs (must match the EA's HMA settings for consistent signals) -----
input int InpFastPeriod = 10;                           // Fast HMA period (12-25 recommended)
input int InpSlowPeriod = 60;                           // Slow HMA period (60-120 recommended)
input ENUM_MA_METHOD InpMethod = MODE_LWMA;             // HMA averaging method
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // Applied price

//----- Output buffers (persistent, index 0 = oldest bar) -----
// 0 = fast value, 1 = fast color index, 2 = slow value, 3 = slow color index
double FastBuf[], FastColor[], SlowBuf[], SlowColor[];

//----- Persistent intermediate buffers (must survive between OnCalculate
//      calls so old bars never need to be recomputed) -----
double g_fastMaHalf[], g_fastMaFull[], g_fastRaw[];
double g_slowMaHalf[], g_slowMaFull[], g_slowRaw[];

//====================================================================
// Generic MA engine (arrays are non-series: index 0 = oldest).
// 'from' is the first index that actually needs (re)computing - every
// index before it is assumed already correct from a previous call.
//====================================================================
void CalcSMA(const double& price[], int total, int period, int from, double& out[]) {
    for (int i = MathMax(from, 0); i < total; i++) {
        if (i < period - 1) {
            out[i] = 0.0;
            continue;
        }
        double sum = 0.0;
        for (int k = 0; k < period; k++)
            sum += price[i - k];
        out[i] = sum / period;
    }
}

void CalcLWMA(const double& price[], int total, int period, int from, double& out[]) {
    double denom = period * (period + 1) / 2.0;
    for (int i = MathMax(from, 0); i < total; i++) {
        if (i < period - 1) {
            out[i] = 0.0;
            continue;
        }
        double sum = 0.0;
        for (int k = 0; k < period; k++)
            sum += price[i - k] * (period - k);
        out[i] = sum / denom;
    }
}

void CalcEMA(const double& price[], int total, int period, int from, double& out[]) {
    double alpha = 2.0 / (period + 1);
    for (int i = MathMax(from, 0); i < total; i++) {
        if (i < period - 1) {
            out[i] = 0.0;
            continue;
        }
        if (i == period - 1) {
            double sum = 0.0;
            for (int k = 0; k < period; k++)
                sum += price[i - k];
            out[i] = sum / period;
        } else
            out[i] = out[i - 1] + alpha * (price[i] - out[i - 1]); // needs out[i-1] already valid
    }
}

void CalcSMMA(const double& price[], int total, int period, int from, double& out[]) {
    for (int i = MathMax(from, 0); i < total; i++) {
        if (i < period - 1) {
            out[i] = 0.0;
            continue;
        }
        if (i == period - 1) {
            double sum = 0.0;
            for (int k = 0; k < period; k++)
                sum += price[i - k];
            out[i] = sum / period;
        } else
            out[i] = (out[i - 1] * (period - 1) + price[i]) / period; // needs out[i-1] already valid
    }
}

void CalcMA(const double& price[], int total, int period, ENUM_MA_METHOD method, int from, double& out[]) {
    if (ArraySize(out) != total)
        ArrayResize(out, total);
    switch (method) {
    case MODE_EMA:
        CalcEMA(price, total, period, from, out);
        break;
    case MODE_SMMA:
        CalcSMMA(price, total, period, from, out);
        break;
    case MODE_LWMA:
        CalcLWMA(price, total, period, from, out);
        break;
    default:
        CalcSMA(price, total, period, from, out);
        break;
    }
}

// Hull MA = MA( 2*MA(price,period/2) - MA(price,period), sqrt(period) )
// maHalf/maFull/raw are the caller's persistent scratch buffers for this
// particular HMA line (fast has its own set, slow has its own set) so
// that indices below 'from' never need to be touched again.
void CalcHMA(const double& price[], int total, int period, ENUM_MA_METHOD method, int from,
             double& maHalf[], double& maFull[], double& raw[], double& hma[]) {
    int halfPeriod = (int)MathMax(1, MathRound(period / 2.0));
    int sqrtPeriod = (int)MathMax(1, MathRound(MathSqrt(period)));

    if (ArraySize(maHalf) != total)
        ArrayResize(maHalf, total);
    if (ArraySize(maFull) != total)
        ArrayResize(maFull, total);
    if (ArraySize(raw) != total)
        ArrayResize(raw, total);

    CalcMA(price, total, halfPeriod, method, from, maHalf);
    CalcMA(price, total, period, method, from, maFull);

    for (int i = MathMax(from, 0); i < total; i++)
        raw[i] = 2.0 * maHalf[i] - maFull[i];

    CalcMA(raw, total, sqrtPeriod, method, from, hma);
}

//====================================================================
int OnInit() {
    SetIndexBuffer(0, FastBuf, INDICATOR_DATA);
    SetIndexBuffer(1, FastColor, INDICATOR_COLOR_INDEX);
    SetIndexBuffer(2, SlowBuf, INDICATOR_DATA);
    SetIndexBuffer(3, SlowColor, INDICATOR_COLOR_INDEX);

    ArraySetAsSeries(FastBuf, false);
    ArraySetAsSeries(FastColor, false);
    ArraySetAsSeries(SlowBuf, false);
    ArraySetAsSeries(SlowColor, false);

    int minBars = MathMax(InpFastPeriod, InpSlowPeriod) + 5;
    PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, minBars);
    PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, minBars);

    IndicatorSetString(INDICATOR_SHORTNAME,
                       StringFormat("HMA Dual (%d,%d)", InpFastPeriod, InpSlowPeriod));
    IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

    return (INIT_SUCCEEDED);
}

//====================================================================
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime& time[],
                const double& open[],
                const double& high[],
                const double& low[],
                const double& close[],
                const long& tick_volume[],
                const long& volume[],
                const int& spread[]) {
    if (rates_total < MathMax(InpFastPeriod, InpSlowPeriod) + 5)
        return (0);

    // Build the applied-price series (non-series, index0 = oldest, matches
    // the open/high/low/close arrays MT5 hands to OnCalculate by default).
    // Cheap O(n) pass - unavoidable and fine even every tick.
    double price[];
    ArrayResize(price, rates_total);
    for (int i = 0; i < rates_total; i++) {
        switch (InpAppliedPrice) {
        case PRICE_OPEN:
            price[i] = open[i];
            break;
        case PRICE_HIGH:
            price[i] = high[i];
            break;
        case PRICE_LOW:
            price[i] = low[i];
            break;
        case PRICE_MEDIAN:
            price[i] = (high[i] + low[i]) / 2.0;
            break;
        case PRICE_TYPICAL:
            price[i] = (high[i] + low[i] + close[i]) / 3.0;
            break;
        case PRICE_WEIGHTED:
            price[i] = (high[i] + low[i] + 2 * close[i]) / 4.0;
            break;
        default:
            price[i] = close[i];
            break;
        }
    }

    // Incremental recompute: only touch bars from 'from' onward. On the very
    // first call (prev_calculated==0) that's everything; afterwards it's just
    // the newest bar (which may have changed) plus any brand-new bars.
    int from = (prev_calculated <= 0) ? 0 : prev_calculated - 1;

    CalcHMA(price, rates_total, InpFastPeriod, InpMethod, from,
            g_fastMaHalf, g_fastMaFull, g_fastRaw, FastBuf);
    CalcHMA(price, rates_total, InpSlowPeriod, InpMethod, from,
            g_slowMaHalf, g_slowMaFull, g_slowRaw, SlowBuf);

    int colorMin = MathMax(InpFastPeriod, InpSlowPeriod) + 1;
    for (int i = MathMax(from, 0); i < rates_total; i++) {
        if (i < colorMin) {
            FastColor[i] = 0;
            SlowColor[i] = 0;
            continue;
        }
        FastColor[i] = (FastBuf[i] >= FastBuf[i - 1]) ? 0 : 1; // 0=up(blue) 1=down(red)
        SlowColor[i] = (SlowBuf[i] >= SlowBuf[i - 1]) ? 0 : 1; // 0=up(blue) 1=down(red)
    }

    return (rates_total);
}
//+------------------------------------------------------------------+