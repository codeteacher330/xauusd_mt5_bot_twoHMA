//+------------------------------------------------------------------+
//|                                     HMA_TrendHold_Angle_EA.mq5    |
//|  Built on HMA_TrendHold_EA, adding:                                |
//|   1) An angle (steepness) filter on the FAST HMA for entries -    |
//|      the fast HMA's slope, converted to degrees via arctan(),     |
//|      must exceed InpMinFastAngleDegrees before opening.           |
//|   2) A time-based delay (minutes) after closing a trade before    |
//|      another one can open - prevents rapid back-to-back entries.  |
//|                                                                    |
//|  Rule:                                                             |
//|   - Flat + both HMAs trend UP + fast angle >= threshold  -> Buy   |
//|   - Flat + both HMAs trend DOWN + fast angle >= threshold -> Sell |
//|   - In a trade + HMAs still agree  -> hold                        |
//|   - In a trade + HMAs diverge      -> close immediately           |
//|     (unless InpEnableAutoClose=false)                             |
//|   - After any close, wait InpDelayMinutes before opening again    |
//|                                                                    |
//|  Requires HMA_Dual.mq5 compiled and present in MQL5\Indicators.   |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

#define HMA_PI 3.14159265358979323846

//====================================================================
// INPUTS
//====================================================================
input group "===== HMA Settings ====="
input int                InpFastHMAPeriod = 21;             // Fast HMA period (recommended 12-25)
input int                InpSlowHMAPeriod = 89;             // Slow HMA period (recommended 60-120)
input ENUM_MA_METHOD      InpHMAMethod     = MODE_LWMA;       // HMA averaging method
input ENUM_APPLIED_PRICE  InpAppliedPrice  = PRICE_CLOSE;     // Applied price
input ENUM_TIMEFRAMES     InpTimeframe     = PERIOD_CURRENT;  // Timeframe used for HMA calculation
input bool                InpShowHMAOnChart = false;           // Attach HMA_Dual indicator lines to chart

input group "===== Angle Filter ====="
input double              InpMinFastAngleDegrees = 20.0;      // Minimum fast HMA slope angle (degrees) required to open (0 = disabled)

input group "===== Trade Delay ====="
input int                 InpDelayMinutes = 15;               // Minimum minutes after a close before opening again (0 = no delay)

input group "===== Exit Behavior ====="
input bool                InpEnableAutoClose = true;         // Auto-close when HMA trends realign (false = only SL/TP closes the trade)
input bool                InpSignalOnCurrentBar = false;      // React immediately on the current forming bar (false = wait for bar close - matches chart colors exactly)

input group "===== Trade Settings ====="
input double  InpLotSize        = 0.10;     // Fixed lot size
input long    InpMagicNumber    = 202603;   // Magic number
input int     InpSlippagePoints = 10;       // Max slippage (points)

input group "===== Stop Loss / Take Profit ====="
enum ENUM_SLTP_MODE
  {
   SLTP_FIXED_POINTS = 0,   // Fixed points
   SLTP_ATR          = 1    // ATR based
  };
input ENUM_SLTP_MODE InpSLTPMode          = SLTP_FIXED_POINTS; // SL/TP calculation mode
input int             InpStopLossPoints   = 1000;              // Stop Loss (points) - fixed mode
input int             InpTakeProfitPoints = 2000;              // Take Profit (points) - fixed mode
input int             InpATRPeriod        = 14;                // ATR period - ATR mode
input double          InpATR_SL_Mult      = 2.0;               // ATR multiplier for SL
input double          InpATR_TP_Mult      = 4.0;               // ATR multiplier for TP

input group "===== Notifications ====="
input bool  InpEnableAlert     = true;    // Popup alert on trade events
input bool  InpVerboseLogging  = true;    // Print trend diagnostics to Experts log each bar

//====================================================================
// GLOBALS
//====================================================================
CTrade      trade;
int         g_atrHandle = INVALID_HANDLE;
int         g_hmaHandle = INVALID_HANDLE;
datetime    g_lastBarTime = 0;
datetime    g_lastCloseTime = 0;   // wall-clock time of the last position close

#define HMA_BUF_FAST 0
#define HMA_BUF_SLOW 2

//====================================================================
// Trend = tangent (slope) between two bars at the given shift.
//====================================================================
bool GetTrend(int bufferIndex, int shiftBars, int &trendOut, double &val0, double &val1)
  {
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(g_hmaHandle,bufferIndex,shiftBars,2,buf) < 2)
      return false;
   val0 = buf[0];
   val1 = buf[1];
   if(val0>val1)      trendOut =  1;
   else if(val0<val1) trendOut = -1;
   else                trendOut =  0;
   return true;
  }

// Converts a per-bar price change into a slope angle in degrees, using the
// broker's point size as the horizontal scale. Signed: positive = rising,
// negative = falling. This is a consistent, reproducible number but is NOT
// a "real world" geometric angle - it depends on the instrument's point
// size, so the right threshold will differ between e.g. gold and EURUSD.
double CalcAngleDegrees(double val0, double val1)
  {
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point<=0) return 0.0;
   double deltaPoints = (val0-val1)/point;
   double angleRad = MathArctan(deltaPoints);
   return angleRad * 180.0 / HMA_PI;
  }

//====================================================================
// POSITION HELPERS
//====================================================================
bool HasOpenPosition(ENUM_POSITION_TYPE &type, ulong &ticket)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      type   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      ticket = tk;
      return true;
     }
   return false;
  }

void CloseAllPositions()
  {
   ENUM_POSITION_TYPE type; ulong ticket;
   bool closedAny=false;
   while(HasOpenPosition(type,ticket))
     {
      trade.PositionClose(ticket,(ulong)InpSlippagePoints);
      closedAny=true;
     }
   if(closedAny)
      g_lastCloseTime = TimeCurrent();
  }

double GetATR()
  {
   double buf[];
   ArraySetAsSeries(buf,true);
   if(CopyBuffer(g_atrHandle,0,0,1,buf) < 1) return 0.0;
   return buf[0];
  }

void Notify(const string msg)
  {
   if(InpEnableAlert) Alert(msg);
   Print(msg);
  }

//====================================================================
// TRADE EXECUTION
//====================================================================
void OpenPosition(bool isBuy)
  {
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double price = isBuy ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                         : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slDistPoints=0, tpDistPoints=0;

   if(InpSLTPMode==SLTP_FIXED_POINTS)
     {
      slDistPoints = InpStopLossPoints;
      tpDistPoints = InpTakeProfitPoints;
     }
   else
     {
      double atr = GetATR();
      if(atr<=0) return;
      slDistPoints = (atr*InpATR_SL_Mult)/point;
      tpDistPoints = (atr*InpATR_TP_Mult)/point;
     }

   // Auto-widen SL/TP to the broker's real minimum distance.
   long stopsLevel  = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   long minLevel    = MathMax(stopsLevel,freezeLevel);
   long safeMin     = minLevel + 10;

   if(minLevel>0 && slDistPoints < safeMin)
     {
      if(InpVerboseLogging)
         Print(StringFormat("HMA_TrendHold_Angle_EA: SL %.1f pts too tight (broker min %ld) - widened to %ld pts.",
               slDistPoints, minLevel, safeMin));
      slDistPoints = (double)safeMin;
     }
   if(minLevel>0 && tpDistPoints < safeMin)
     {
      if(InpVerboseLogging)
         Print(StringFormat("HMA_TrendHold_Angle_EA: TP %.1f pts too tight (broker min %ld) - widened to %ld pts.",
               tpDistPoints, minLevel, safeMin));
      tpDistPoints = (double)safeMin;
     }

   double sl = isBuy ? price - slDistPoints*point : price + slDistPoints*point;
   double tp = isBuy ? price + tpDistPoints*point : price - tpDistPoints*point;

   trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   trade.SetExpertMagicNumber(InpMagicNumber);

   bool ok = isBuy ? trade.Buy(InpLotSize,_Symbol,price,sl,tp,"HMA_TrendHold_Angle_EA")
                    : trade.Sell(InpLotSize,_Symbol,price,sl,tp,"HMA_TrendHold_Angle_EA");

   uint retcode = trade.ResultRetcode();
   if(!ok || (retcode!=TRADE_RETCODE_DONE && retcode!=TRADE_RETCODE_DONE_PARTIAL))
     {
      Notify(StringFormat("HMA_TrendHold_Angle_EA: %s order FAILED. Retcode=%u (%s).",
                           isBuy?"BUY":"SELL", retcode, trade.ResultRetcodeDescription()));
      return;
     }

   Notify(StringFormat("HMA_TrendHold_Angle_EA: %s opened. Lots=%.2f SL=%.5f TP=%.5f",
                        isBuy?"BUY":"SELL", InpLotSize, sl, tp));
  }

//====================================================================
// EXPERT EVENTS
//====================================================================
int OnInit()
  {
   if(InpSLTPMode==SLTP_ATR)
     {
      g_atrHandle = iATR(_Symbol,InpTimeframe,InpATRPeriod);
      if(g_atrHandle==INVALID_HANDLE)
        {
         Print("HMA_TrendHold_Angle_EA: failed to create ATR handle.");
         return(INIT_FAILED);
        }
     }

   g_hmaHandle = iCustom(_Symbol, InpTimeframe, "HMA_Dual",
                          InpFastHMAPeriod, InpSlowHMAPeriod,
                          InpHMAMethod, InpAppliedPrice);
   if(g_hmaHandle==INVALID_HANDLE)
     {
      Print("HMA_TrendHold_Angle_EA: failed to load HMA_Dual indicator. Make sure it's ",
            "compiled and present in MQL5\\Indicators\\.");
      return(INIT_FAILED);
     }

   if(InpShowHMAOnChart) ChartIndicatorAdd(0,0,g_hmaHandle);

   trade.SetExpertMagicNumber(InpMagicNumber);
   Print("HMA_TrendHold_Angle_EA: initialized. Fast=",InpFastHMAPeriod," Slow=",InpSlowHMAPeriod,
         " MinAngle=",InpMinFastAngleDegrees," DelayMin=",InpDelayMinutes);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle!=INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_hmaHandle!=INVALID_HANDLE) IndicatorRelease(g_hmaHandle);
  }

void OnTick()
  {
   int shift;
   if(InpSignalOnCurrentBar)
     {
      shift = 0;
     }
   else
     {
      datetime curBarTime = iTime(_Symbol,InpTimeframe,0);
      if(curBarTime == g_lastBarTime) return;
      g_lastBarTime = curBarTime;
      shift = 1;
     }

   int fastTrend=0, slowTrend=0;
   double fv0,fv1,sv0,sv1;

   if(!GetTrend(HMA_BUF_FAST, shift, fastTrend, fv0, fv1))
     {
      if(InpVerboseLogging) Print("HMA_TrendHold_Angle_EA: not enough history yet (fast HMA).");
      return;
     }
   if(!GetTrend(HMA_BUF_SLOW, shift, slowTrend, sv0, sv1))
     {
      if(InpVerboseLogging) Print("HMA_TrendHold_Angle_EA: not enough history yet (slow HMA).");
      return;
     }

   ENUM_POSITION_TYPE posType; ulong posTicket;
   bool hasPos = HasOpenPosition(posType,posTicket);
   bool agree  = (fastTrend!=0 && fastTrend==slowTrend);
   bool differ = (fastTrend!=0 && slowTrend!=0 && fastTrend!=slowTrend);

   double fastAngle = CalcAngleDegrees(fv0,fv1);

   if(InpVerboseLogging)
      Print(StringFormat("HMA_TrendHold_Angle_EA: fast(%.5f->%.5f)=%d angle=%.2f slow(%.5f->%.5f)=%d agree=%s hasPos=%s",
            fv1,fv0,fastTrend,fastAngle, sv1,sv0,slowTrend, agree?"true":"false", hasPos?"true":"false"));

   if(hasPos)
     {
      // Close as soon as the two HMAs disagree (angle filter does not
      // apply to exits - only used to gate new entries).
      if(InpEnableAutoClose && differ)
        {
         CloseAllPositions();
         Notify("HMA_TrendHold_Angle_EA: HMA trends diverged - position closed.");
        }
     }
   else
     {
      if(!agree) return; // both HMAs must trend the same direction

      // Angle filter: fast HMA's slope must be steep enough.
      if(InpMinFastAngleDegrees>0 && MathAbs(fastAngle) < InpMinFastAngleDegrees)
        {
         if(InpVerboseLogging)
            Print(StringFormat("HMA_TrendHold_Angle_EA: entry skipped - angle %.2f < min %.2f.",
                  MathAbs(fastAngle), InpMinFastAngleDegrees));
         return;
        }

      // Delay filter: enough time must have passed since the last close.
      if(InpDelayMinutes>0 && g_lastCloseTime>0)
        {
         long secondsSinceClose = (long)(TimeCurrent()-g_lastCloseTime);
         long secondsRequired   = (long)InpDelayMinutes*60;
         if(secondsSinceClose < secondsRequired)
           {
            if(InpVerboseLogging)
               Print(StringFormat("HMA_TrendHold_Angle_EA: entry skipped - delay active (%ld of %ld sec elapsed).",
                     secondsSinceClose, secondsRequired));
            return;
           }
        }

      OpenPosition(fastTrend>0);
     }
  }
//+------------------------------------------------------------------+