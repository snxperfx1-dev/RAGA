//+------------------------------------------------------------------+
//|                                          Letra37EA_AllInOne.mq5  |
//|   Autonomous Expert Advisor - faithful single-file MQL5 port of  |
//|   the "Letra 37" Pine Script v6 engine + the full F72 recursive  |
//|   curve framework: 14-phase structure engine, adaptive TF        |
//|   ladder, Time Intelligence Engine, recursive curve TREE         |
//|   (per-node ownership/FU-merge), multi-timeframe curve OWNERSHIP  |
//|   map (transfer ladder / Wyckoff four-shift / entry architecture),|
//|   curve ownership (building-vs-entry, budget) and the curve-life |
//|   "is the trade alive?" manager.                                 |
//|   Keeps the Letra decision layer; excludes the Senseei layer.    |
//|                                                                  |
//|   COMBINED build: every module inlined in dependency order.      |
//+------------------------------------------------------------------+
#property copyright "Letra 37 Port"
#property version   "1.40"
#property strict

#include <Trade/Trade.mqh>


// =================================================================
// ==== INLINED: Include/Letra37/PineRuntime.mqh
// =================================================================
//+------------------------------------------------------------------+
//|                                              PineRuntime.mqh      |
//|     Pine Script v6 -> MQL5 runtime compatibility layer           |
//|     Part of the Letra 37 autonomous EA port                      |
//+------------------------------------------------------------------+
//  This module reproduces the primitives that Pine Script provides
//  implicitly so the ported engines can mirror the original logic
//  line-for-line:
//    * na / nz semantics for floating point "missing" values
//    * historical series access  value[n]  via a ring buffer
//    * ta.ema / ta.rma / ta.sma / ta.atr stateful series functions
//    * ta.highest / ta.lowest / math.sum over a window
//    * ta.pivothigh / ta.pivotlow confirmed-pivot detection
//
//  All engines are advanced one CLOSED bar at a time (exactly like
//  Pine evaluates one bar at a time), so every stateful helper here
//  is updated once per bar in the same order as the source script.
//+------------------------------------------------------------------+

//--- "na" sentinel.  Pine uses a dedicated NaN; we use a sentinel that
//--- never collides with a real price and provide helpers around it.
#define PINE_NA  (DBL_MAX)

//+------------------------------------------------------------------+
//| na / nz helpers                                                  |
//+------------------------------------------------------------------+
bool IsNa(const double v)            { return(v==PINE_NA || !MathIsValidNumber(v)); }
double Nz(const double v)            { return(IsNa(v) ? 0.0 : v); }
double Nz(const double v,const double rep) { return(IsNa(v) ? rep : v); }
int    NzI(const int v,const int rep)      { return(v==INT_MIN ? rep : v); }

double PineMin(const double a,const double b){ if(IsNa(a)) return b; if(IsNa(b)) return a; return(a<b?a:b); }
double PineMax(const double a,const double b){ if(IsNa(a)) return b; if(IsNa(b)) return a; return(a>b?a:b); }
double Clamp(const double v,const double lo,const double hi){ return(v<lo?lo:(v>hi?hi:v)); }

//+------------------------------------------------------------------+
//| CRing - growable-but-capped historical series (value[n] access)  |
//|   Push() once per bar with the bar's value.                      |
//|   Get(lag): lag 0 = most recently pushed (current bar).          |
//+------------------------------------------------------------------+
class CRing
  {
private:
   double            m_b[];
   int               m_cap;
   long              m_count;   // total values ever pushed
public:
                     CRing(void): m_cap(0), m_count(0) {}
   void              Init(const int cap)
     {
      m_cap = (cap<8 ? 8 : cap);
      ArrayResize(m_b, m_cap);
      ArrayInitialize(m_b, 0.0);
      m_count = 0;
     }
   void              Push(const double v)
     {
      if(m_cap<=0) Init(1024);
      m_b[(int)(m_count % m_cap)] = v;
      m_count++;
     }
   long              Count(void) const { return m_count; }
   bool              Has(const int lag) const { return(lag>=0 && lag<m_cap && (long)lag<m_count); }
   //--- lag 0 = current (last pushed); returns PINE_NA if unavailable
   double            Get(const int lag) const
     {
      if(m_count==0) return PINE_NA;
      if(lag<0 || lag>=m_cap || (long)lag>=m_count) return PINE_NA;
      long idx = m_count-1-lag;
      return m_b[(int)(idx % m_cap)];
     }
   //--- highest / lowest of the most recent `len` values (incl. current)
   double            Highest(const int len) const
     {
      int n=(int)MathMin((long)len,m_count);
      if(n<=0) return PINE_NA;
      double mx=-DBL_MAX;
      for(int i=0;i<n;i++){ double v=Get(i); if(!IsNa(v) && v>mx) mx=v; }
      return(mx==-DBL_MAX?PINE_NA:mx);
     }
   double            Lowest(const int len) const
     {
      int n=(int)MathMin((long)len,m_count);
      if(n<=0) return PINE_NA;
      double mn=DBL_MAX;
      for(int i=0;i<n;i++){ double v=Get(i); if(!IsNa(v) && v<mn) mn=v; }
      return(mn==DBL_MAX?PINE_NA:mn);
     }
   //--- math.sum over most recent `len` values
   double            Sum(const int len) const
     {
      int n=(int)MathMin((long)len,m_count);
      double s=0.0;
      for(int i=0;i<n;i++){ double v=Get(i); if(!IsNa(v)) s+=v; }
      return s;
     }
  };

//+------------------------------------------------------------------+
//| CEma - stateful exponential moving average  (ta.ema)             |
//|   alpha = 2 / (len + 1)                                          |
//+------------------------------------------------------------------+
class CEma
  {
private:
   double            m_val;
   double            m_alpha;
   bool              m_init;
public:
                     CEma(void): m_val(0), m_alpha(0), m_init(false) {}
   void              Init(const int len){ m_alpha=2.0/(len+1.0); m_init=false; m_val=0.0; }
   void              SetAlpha(const double a){ m_alpha=a; }
   double            Update(const double src)
     {
      if(IsNa(src)) return m_val;
      if(!m_init){ m_val=src; m_init=true; }
      else        m_val = m_alpha*src + (1.0-m_alpha)*m_val;
      return m_val;
     }
   double            Value(void) const { return(m_init?m_val:PINE_NA); }
   bool              Ready(void) const { return m_init; }
  };

//+------------------------------------------------------------------+
//| CRma - Wilder running moving average (ta.rma, used by ta.atr)    |
//|   alpha = 1 / len ; seeded with SMA of first `len` samples       |
//+------------------------------------------------------------------+
class CRma
  {
private:
   double            m_val;
   double            m_alpha;
   int               m_len;
   int               m_seen;
   double            m_seedSum;
   bool              m_init;
public:
                     CRma(void): m_val(0), m_alpha(0), m_len(1), m_seen(0), m_seedSum(0), m_init(false) {}
   void              Init(const int len){ m_len=(len<1?1:len); m_alpha=1.0/m_len; m_seen=0; m_seedSum=0.0; m_init=false; m_val=0.0; }
   double            Update(const double src)
     {
      if(IsNa(src)) return (m_init?m_val:PINE_NA);
      if(!m_init)
        {
         m_seen++;
         m_seedSum += src;
         if(m_seen>=m_len){ m_val=m_seedSum/m_len; m_init=true; }
         return (m_init?m_val:PINE_NA);
        }
      m_val = m_alpha*src + (1.0-m_alpha)*m_val;
      return m_val;
     }
   double            Value(void) const { return(m_init?m_val:PINE_NA); }
   bool              Ready(void) const { return m_init; }
  };

//+------------------------------------------------------------------+
//| CSma - simple moving average over a window (ta.sma)              |
//+------------------------------------------------------------------+
class CSma
  {
private:
   CRing             m_r;
   int               m_len;
public:
                     CSma(void): m_len(1) {}
   void              Init(const int len){ m_len=(len<1?1:len); m_r.Init(len+2); }
   double            Update(const double src)
     {
      m_r.Push(IsNa(src)?0.0:src);
      int n=(int)MathMin((long)m_len, m_r.Count());
      if(n<=0) return PINE_NA;
      return m_r.Sum(m_len)/n;
     }
  };

//+------------------------------------------------------------------+
//| Pivot detection helpers.                                         |
//|   Pine ta.pivothigh(src, L, L): confirmed at the current bar; the|
//|   pivot itself sits L bars back. Returns the pivot price or NA.  |
//|   We evaluate using a ring that holds at least 2*L+1 samples.    |
//+------------------------------------------------------------------+
//  ring: series of the source (high for pivothigh, low for pivotlow)
//  leftright: the L parameter (same on both sides)
//  Returns pivot value if bar at lag `leftright` is a strict pivot.
double PivotHigh(const CRing &ring,const int leftright)
  {
   int need = 2*leftright+1;
   if(ring.Count() < need) return PINE_NA;
   double pivot = ring.Get(leftright);
   if(IsNa(pivot)) return PINE_NA;
   for(int i=1;i<=leftright;i++)
     {
      double l = ring.Get(leftright+i); // older (left)
      double r = ring.Get(leftright-i); // newer (right)
      if(IsNa(l) || IsNa(r)) return PINE_NA;
      if(!(pivot> l)) return PINE_NA;
      if(!(pivot> r)) return PINE_NA;
     }
   return pivot;
  }

double PivotLow(const CRing &ring,const int leftright)
  {
   int need = 2*leftright+1;
   if(ring.Count() < need) return PINE_NA;
   double pivot = ring.Get(leftright);
   if(IsNa(pivot)) return PINE_NA;
   for(int i=1;i<=leftright;i++)
     {
      double l = ring.Get(leftright+i);
      double r = ring.Get(leftright-i);
      if(IsNa(l) || IsNa(r)) return PINE_NA;
      if(!(pivot< l)) return PINE_NA;
      if(!(pivot< r)) return PINE_NA;
     }
   return pivot;
  }

//+------------------------------------------------------------------+
//| Rounding helper mirroring Pine math.round                        |
//+------------------------------------------------------------------+
int PineRound(const double v){ return (int)MathRound(v); }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/Inputs.mqh
// =================================================================
//+------------------------------------------------------------------+
//|                                                   Inputs.mqh     |
//|     All tunable parameters for the Letra 37 EA.                  |
//|     Names/defaults mirror the original Pine "Letra 37" inputs,   |
//|     plus an Execution/Risk group for autonomous trading.         |
//+------------------------------------------------------------------+

//==================== CORE SETTINGS ===============================
input group "Core Settings"
input int    InpPivotLen        = 5;     // Pivot Length
input int    InpAtrLen          = 14;    // ATR Length
input int    InpEffLen          = 10;    // Efficiency Lookback
input int    InpResetBars       = 20;    // Min Bars Before Reset

//==================== DISPLACEMENT & FILTERS ======================
input group "Displacement & Filters"
input double InpImpulseAtrMult  = 1.5;   // Impulse ATR Multiple
input double InpRetrMin         = 0.3;   // Min Retracement
input double InpRetrMax         = 0.8;   // Max Retracement
input double InpEffThresh       = 0.65;  // Efficiency Threshold
input double InpDispThresh      = 1.5;   // Displacement ATR Threshold
input double InpConvMult        = 0.01;  // Convexity ATR Multiplier
input int    InpAcceptBars      = 2;     // Flipzone Acceptance Bars
input int    InpObLookback      = 8;     // Order Block Lookback Bars
input int    InpObMaxBars       = 50;    // OB Max Valid Bars

//==================== MARKET STRUCTURE ============================
input group "Market Structure"
input bool   InpUseStrictStruct = true;  // Use Strict Structure
input int    InpStructLen       = 10;    // Structure Pivot Length
input bool   InpRequireStruct   = true;  // Require Structure Confirm
input double InpChochBufferATR  = 0.75;  // Direction CHoCH Buffer (ATR)

//==================== INDUCEMENT ENGINE ===========================
input group "Inducement Engine"
input int    InpInducLookback   = 80;    // Inducement Lookback Bars
input double InpInducZoneWidth  = 0.25;  // Inducement Zone Half-Width (ATR)
input bool   InpRequirePreConv  = true;  // Require Pre-Convexity Evidence
input bool   InpRequireInduction= true;  // Require Induction Evidence

//==================== LIQUIDITY ENGINE ============================
input group "Liquidity Engine"
input double InpLiqRadius       = 0.25;  // Liquidity Radius (x ATR)
input double InpLiqAgDecay      = 0.95;  // Age Decay Factor
input bool   InpRequireLiqSweep = true;  // Require Liquidity Sweep for Entry
input int    InpLiqSweepLookback= 10;    // Sweep Lookback Bars

//==================== MULTI-TIMEFRAME =============================
input group "Multi-Timeframe"
input ENUM_TIMEFRAMES InpTf1    = PERIOD_M15; // Timeframe 1 (HTF Bias)
input ENUM_TIMEFRAMES InpTf2    = PERIOD_H1;  // Timeframe 2 (HTF Bias)

//==================== EXECUTION CONTROLS ==========================
input group "Execution Controls"
input int    InpBaseLockBars    = 10;    // Base Lock Bars After Entry Fire
input bool   InpRequireHTFAlign = false; // Require HTF Bias Alignment
input double InpExecThreshold   = 5.0;   // Net Edge Execution Threshold

//==================== INTELLIGENCE ENGINE =========================
input group "Intelligence Engine"
input int    InpBeliefSmooth    = 3;     // Belief EMA Smoothing
input double InpConfDecayRate   = 0.02;  // Confidence Decay Rate
input double InpDevReinterp      = 30.0; // Deviation Reinterpret Threshold

//==================== ENERGY RESOLUTION FRAMEWORK =================
input group "Energy Resolution Framework (ERF)"
input double InpErfReadyResW    = 0.25;  // ERF: Recursive Completion Weight
input double InpErfReadyResidW  = 0.20;  // ERF: Delivered Energy Weight
input double InpErfReadyConfW   = 0.15;  // ERF: Confidence Weight
input double InpErfEntryThresh  = 45.0;  // ERF: Entry Gate Threshold
input bool   InpErfGateEnabled  = true;  // ERF: Enable Entry Gate on Signals

//==================== SIGNALS =====================================
input group "Signal Gating"
input bool   InpShowSignals     = true;  // Enable Entry Signal Generation
input bool   InpUseGradeFilter  = true;  // Apply Setup Grade Filter

//==================== TRADE EXECUTION / RISK ======================
input group "Trade Execution & Risk"
input bool   InpEnableTrading   = true;        // Enable Live Order Execution
input ENUM_TIMEFRAMES InpWorkTF = PERIOD_M5;   // Working / Chart-Context Timeframe
input double InpRiskPercent     = 0.5;         // Risk % of equity per trade
input double InpFixedLots       = 0.0;         // Fixed lots (0 = use Risk %)
input double InpSL_ATR          = 1.5;         // Stop Loss (x ATR)
input double InpTP_ATR          = 3.0;         // Take Profit (x ATR, 0 = none)
input bool   InpUseStructSL     = true;        // Use flip-zone / invalidation for SL
input bool   InpUseTrailing     = true;        // Enable ATR trailing stop
input double InpTrailATR        = 2.0;         // Trailing distance (x ATR)
input double InpTrailStartATR   = 1.0;         // Start trailing after (x ATR) profit
input bool   InpUseBreakeven    = true;        // Move SL to breakeven
input double InpBE_ATR          = 1.0;         // Breakeven trigger (x ATR profit)
input bool   InpCloseOnExit     = true;        // Close positions on engine EXIT signal
input int    InpMaxPositions    = 1;           // Max simultaneous positions (this EA)
input int    InpMaxSpreadPoints = 40;          // Max spread (points) to allow entry
input double InpMaxDailyLossPct = 5.0;         // Daily loss limit (% equity, 0=off)
input double InpMaxTotalDDPct   = 20.0;        // Total drawdown halt (% peak equity, 0=off)
input long   InpMagic           = 370037;      // Magic number
input int    InpSlippagePoints  = 20;          // Max deviation (points)
input string InpTradeComment    = "Letra37";   // Order comment

//==================== CURVE-LIFE MANAGEMENT (F72) ================
input group "Curve-Life Management (F72)"
input bool   InpUseCurveLife       = true;  // Use F72 curve-life to manage open trades
input bool   InpCurveLifeFlatOnDead= true;  // Close position when owning curve is DEAD
input bool   InpCurveLifeTightenWeak=true;  // Move SL to breakeven when WEAKENING

//==================== SESSION FILTER ==============================
input group "Session Filter"
input bool   InpUseSession      = false;       // Restrict trading to a session
input int    InpSessionStartHr  = 7;           // Session start hour (server time)
input int    InpSessionEndHr    = 20;          // Session end hour (server time)
input bool   InpTradeMonday     = true;
input bool   InpTradeFriday     = true;

//==================== FU ORDER BLOCKS (advisory) ==================
input group "FU Order Blocks (advisory)"
input int    InpFuLookback      = 3;     // FU Detection Lookback Bars
input double InpFuMinBodyRatio  = 0.6;   // Min Body/Range Ratio (FU candle)
input double InpFuMinWickRatio  = 0.25;  // Min Wick Ratio
input int    InpFuMaxBarsActive = 75;    // FU Zone Max Active Bars
input bool   InpFuRequireInZone = true;  // Require Price in Wave Zone

//==================== FUTURE RETURN ZONES (advisory) ==============
input group "Future Return Zones (advisory)"
input int    InpFrzMinScore     = 26;    // Min FRZ Score to Display (0-100)
input int    InpFrzMaxBarsActive= 100;   // FRZ Max Active Bars

//==================== DISPLAY =====================================
input group "Display"
input bool   InpShowDashboard   = true;        // Show on-chart dashboard panel
input int    InpDashCorner      = 0;           // Corner (0=TL,1=TR,2=BL,3=BR)
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/Context.mqh
// =================================================================
//+------------------------------------------------------------------+
//|                                                  Context.mqh     |
//|     Shared global state + multi-timeframe bar feeders.           |
//|     Holds the "chart context" working-timeframe OHLCV history    |
//|     (mirroring Pine's chart series) and resolved config.         |
//|                                                                  |
//|     Orchestration (warm-up + per-bar pipeline) lives in          |
//|     Pipeline.mqh, included last so every engine function is      |
//|     already declared.                                            |
//+------------------------------------------------------------------+

//==================================================================
//  Resolved configuration (aliases mirroring Pine input names).
//  Kept as plain globals so engine modules read them like the
//  original script did.
//==================================================================
int    cfg_pivotLen, cfg_atrLen, cfg_effLen, cfg_resetBars;
double cfg_impulseAtrMult, cfg_retrMin, cfg_retrMax, cfg_effThresh, cfg_dispThresh, cfg_convMult;
int    cfg_acceptBars, cfg_obLookback, cfg_obMaxBars;
bool   cfg_useStrictStruct, cfg_requireStruct;
int    cfg_structLen;
double cfg_chochBufferATR;
int    cfg_inducLookback;
double cfg_inducZoneWidth;
bool   cfg_requirePreConv, cfg_requireInduction;
double cfg_liqRadius, cfg_liqAgDecay;
bool   cfg_requireLiqSweep;
int    cfg_liqSweepLookback;
int    cfg_baseLockBars;
bool   cfg_requireHTFAlign;
double cfg_execThreshold;
int    cfg_beliefSmooth;
double cfg_confDecayRate, cfg_devReinterp;
double cfg_erfReadyResW, cfg_erfReadyResidW, cfg_erfReadyConfW, cfg_erfEntryThresh;
bool   cfg_erfGateEnabled;
bool   cfg_showSignals, cfg_useGradeFilter;

ENUM_TIMEFRAMES cfg_tf1, cfg_tf2, cfg_workTF;

//==================================================================
//  Working-timeframe (chart context) series + bar index
//==================================================================
CRing g_O, g_H, g_L, g_C, g_V;     // open/high/low/close/volume rings
long  g_barIndex = -1;             // mirrors Pine bar_index (0-based)
datetime g_lastWorkBarTime = 0;    // last processed work-TF bar open time

//==================================================================
//  Adaptive timeframe ladder (V60 fix).
//  The six structure engines run on g_ladderTF[0..5] (rung 3 / index 2
//  is the canonical Engine-1A wave). At/below H1 the ladder is the
//  native intraday set M1/M3/M5/M15/H1/H4 (unchanged behaviour). Above
//  H1 it CLIMBS the standard MT5 timeframes instead of collapsing every
//  rung to the chart timeframe (which used to pin the fractal score at
//  100%); all six rungs stay distinct and >= the work timeframe.
//==================================================================
ENUM_TIMEFRAMES g_ladderTF[6];

void Ctx_BuildLadder()
  {
   int sec = PeriodSeconds(cfg_workTF);
   if(sec<=3600)
     {
      g_ladderTF[0]=PERIOD_M1;  g_ladderTF[1]=PERIOD_M3;  g_ladderTF[2]=PERIOD_M5;
      g_ladderTF[3]=PERIOD_M15; g_ladderTF[4]=PERIOD_H1;  g_ladderTF[5]=PERIOD_H4;
      return;
     }
   ENUM_TIMEFRAMES master[9];
   master[0]=PERIOD_M1;  master[1]=PERIOD_M3;  master[2]=PERIOD_M5;
   master[3]=PERIOD_M15; master[4]=PERIOD_H1;  master[5]=PERIOD_H4;
   master[6]=PERIOD_D1;  master[7]=PERIOD_W1;  master[8]=PERIOD_MN1;
   int wi=8;
   for(int i=0;i<9;i++){ if(PeriodSeconds(master[i])>=sec){ wi=i; break; } }
   int start=wi-2; if(start<0) start=0; if(start>3) start=3;
   for(int i=0;i<6;i++) g_ladderTF[i]=master[start+i];
  }

//--- convenience accessors for "current bar" chart series
double C_close(const int lag=0){ return g_C.Get(lag); }
double C_open (const int lag=0){ return g_O.Get(lag); }
double C_high (const int lag=0){ return g_H.Get(lag); }
double C_low  (const int lag=0){ return g_L.Get(lag); }
double C_vol  (const int lag=0){ return g_V.Get(lag); }

#define CTX_RING_CAP 1024

//==================================================================
//  Load inputs into the resolved-config globals
//==================================================================
void Ctx_LoadInputs()
  {
   cfg_pivotLen       = InpPivotLen;
   cfg_atrLen         = InpAtrLen;
   cfg_effLen         = InpEffLen;
   cfg_resetBars      = InpResetBars;
   cfg_impulseAtrMult = InpImpulseAtrMult;
   cfg_retrMin        = InpRetrMin;
   cfg_retrMax        = InpRetrMax;
   cfg_effThresh      = InpEffThresh;
   cfg_dispThresh     = InpDispThresh;
   cfg_convMult       = InpConvMult;
   cfg_acceptBars     = InpAcceptBars;
   cfg_obLookback     = InpObLookback;
   cfg_obMaxBars      = InpObMaxBars;
   cfg_useStrictStruct= InpUseStrictStruct;
   cfg_requireStruct  = InpRequireStruct;
   cfg_structLen      = InpStructLen;
   cfg_chochBufferATR = InpChochBufferATR;
   cfg_inducLookback  = InpInducLookback;
   cfg_inducZoneWidth = InpInducZoneWidth;
   cfg_requirePreConv = InpRequirePreConv;
   cfg_requireInduction = InpRequireInduction;
   cfg_liqRadius      = InpLiqRadius;
   cfg_liqAgDecay     = InpLiqAgDecay;
   cfg_requireLiqSweep= InpRequireLiqSweep;
   cfg_liqSweepLookback = InpLiqSweepLookback;
   cfg_baseLockBars   = InpBaseLockBars;
   cfg_requireHTFAlign= InpRequireHTFAlign;
   cfg_execThreshold  = InpExecThreshold;
   cfg_beliefSmooth   = InpBeliefSmooth;
   cfg_confDecayRate  = InpConfDecayRate;
   cfg_devReinterp    = InpDevReinterp;
   cfg_erfReadyResW   = InpErfReadyResW;
   cfg_erfReadyResidW = InpErfReadyResidW;
   cfg_erfReadyConfW  = InpErfReadyConfW;
   cfg_erfEntryThresh = InpErfEntryThresh;
   cfg_erfGateEnabled = InpErfGateEnabled;
   cfg_showSignals    = InpShowSignals;
   cfg_useGradeFilter = InpUseGradeFilter;
   cfg_tf1            = InpTf1;
   cfg_tf2            = InpTf2;
   cfg_workTF         = InpWorkTF;

   Ctx_BuildLadder();

   g_O.Init(CTX_RING_CAP);
   g_H.Init(CTX_RING_CAP);
   g_L.Init(CTX_RING_CAP);
   g_C.Init(CTX_RING_CAP);
   g_V.Init(CTX_RING_CAP);
   g_barIndex = -1;
  }

//==================================================================
//  Push one closed work-TF bar into the chart-context rings
//==================================================================
void Ctx_PushWorkBar(const double o,const double h,const double l,const double c,const double v)
  {
   g_O.Push(o);
   g_H.Push(h);
   g_L.Push(l);
   g_C.Push(c);
   g_V.Push(v);
   g_barIndex++;
  }

//==================================================================
//  Generic per-timeframe feeder.
//  Feeds every CLOSED bar of `tf` whose close-time is <= `moment`
//  and that has not yet been processed, in chronological order,
//  invoking the supplied handler id via the dispatcher below.
//
//  Returns through out-arrays; the actual engine handlers live in
//  their modules and are dispatched from Pipeline.mqh.
//==================================================================
//  We expose a primitive that, given a tf and a "lastOpenTime"
//  cursor and a target moment, returns the list of bar shifts to
//  process (oldest first). The caller feeds them to the engine.
int Ctx_PendingBars(const ENUM_TIMEFRAMES tf,const datetime lastOpenTime,const datetime moment,
                    int &shiftsOut[])
  {
   ArrayResize(shiftsOut,0);
   int per = PeriodSeconds(tf);
   if(per<=0) return 0;
   int bars = Bars(_Symbol, tf);
   if(bars<=1) return 0;

   //--- endShift = smallest shift (>=1) whose bar has CLOSED by `moment`
   //    (closeTime = openTime + period <= moment). As shift grows, time falls.
   int endShift = 1;
   while(endShift<bars-1)
     {
      datetime ot = iTime(_Symbol, tf, endShift);
      if(ot==0){ endShift++; continue; }
      if((datetime)(ot+per) <= moment) break;
      endShift++;
     }

   //--- startShift = oldest unprocessed closed bar (largest shift) with
   //    openTime > lastOpenTime. Bars newer than lastOpenTime have smaller shift.
   int startShift;
   if(lastOpenTime<=0)
      startShift = bars-1;
   else
     {
      int ls = iBarShift(_Symbol, tf, lastOpenTime, false);
      startShift = (ls<0) ? bars-1 : ls-1;   // strictly newer than lastOpenTime
     }
   if(startShift>bars-1) startShift = bars-1;

   //--- bound the batch to the most-recent bars (warm-up backlog safety)
   int MAX_FEED = 8000;
   if(startShift - endShift + 1 > MAX_FEED) startShift = endShift + MAX_FEED - 1;

   //--- emit shifts oldest -> newest (largest shift down to endShift)
   for(int s=startShift; s>=endShift; s--)
     {
      datetime ot = iTime(_Symbol, tf, s);
      if(ot==0) continue;
      if(ot<=lastOpenTime) continue;
      if((datetime)(ot+per) > moment) continue;
      int n=ArraySize(shiftsOut); ArrayResize(shiftsOut,n+1); shiftsOut[n]=s;
     }
   return ArraySize(shiftsOut);
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/SharedState.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  SharedState.mqh - cross-module wave-context + forward vars      |
//|                                                                  |
//|  The source declares these in SECTION 8 (and the "FORWARD        |
//|  DECLARATIONS" block) BEFORE the engines that read them, so      |
//|  earlier engines see the PREVIOUS bar's value and SECTION 13     |
//|  (wave spawn) writes the new value. Declaring them here -        |
//|  included right after Context and before every engine module -   |
//|  preserves that exact read-before-write (1-bar lag) behaviour.   |
//+------------------------------------------------------------------+

//==================== SECTION 8 - WAVE CONTEXT ====================
int    direction          = 0;
double flipTop            = PINE_NA;
double flipBot            = PINE_NA;
long   obBirthBar         = -1;
int    barsInZone         = 0;
long   contBar            = -1;

double point4OriginHigh   = PINE_NA;
double point4OriginLow    = PINE_NA;
long   point4OriginBar    = -1;

double flipzoneInducPrice = PINE_NA;
double flipzoneInducLow   = PINE_NA;
double flipzoneInducHigh  = PINE_NA;

double inducExpOriginHigh  = PINE_NA;
double inducExpExtremeLow  = PINE_NA;
double inducExpOriginLow   = PINE_NA;
double inducExpExtremeHigh = PINE_NA;

double inducRetrOriginHigh  = PINE_NA;
double inducRetrExtremeLow  = PINE_NA;
double inducRetrOriginLow    = PINE_NA;
double inducRetrExtremeHigh = PINE_NA;

double inducZoneLow  = PINE_NA;
double inducZoneHigh = PINE_NA;

double cycleHigh = PINE_NA;
double cycleLow  = PINE_NA;

int    waveGeneration  = 0;
int    entryCycle      = 0;
bool   isRecursiveWave = false;
int    waveDepth       = 0;
int    lastSpawnDir    = 0;
bool   recursiveComplete = false;

bool   recursiveJustFired = false;
long   recursiveFiredBar  = -1;

double retestHigh = PINE_NA;
double retestLow  = PINE_NA;

//==================== FORWARD-DECLARED VARS =======================
double liqHeat            = 0.0;
bool   nearFlipzone       = false;
double convexityMaturity  = 0.0;
bool   closeInside        = false;
bool   preConvEvidence    = false;
bool   inductionEvidence  = false;

//--- ERF gate flags (read by WaveSpawn before Erf module is included)
bool   erf_entryGate      = true;
bool   erf_suppressRotation = false;

//==================================================================
void SharedState_Init()
  {
   direction=0; flipTop=PINE_NA; flipBot=PINE_NA; obBirthBar=-1; barsInZone=0; contBar=-1;
   point4OriginHigh=PINE_NA; point4OriginLow=PINE_NA; point4OriginBar=-1;
   flipzoneInducPrice=PINE_NA; flipzoneInducLow=PINE_NA; flipzoneInducHigh=PINE_NA;
   inducExpOriginHigh=PINE_NA; inducExpExtremeLow=PINE_NA; inducExpOriginLow=PINE_NA; inducExpExtremeHigh=PINE_NA;
   inducRetrOriginHigh=PINE_NA; inducRetrExtremeLow=PINE_NA; inducRetrOriginLow=PINE_NA; inducRetrExtremeHigh=PINE_NA;
   inducZoneLow=PINE_NA; inducZoneHigh=PINE_NA;
   cycleHigh=PINE_NA; cycleLow=PINE_NA;
   waveGeneration=0; entryCycle=0; isRecursiveWave=false; waveDepth=0; lastSpawnDir=0; recursiveComplete=false;
   recursiveJustFired=false; recursiveFiredBar=-1;
   retestHigh=PINE_NA; retestLow=PINE_NA;
   liqHeat=0.0; nearFlipzone=false; convexityMaturity=0.0;
   closeInside=false; preConvEvidence=false; inductionEvidence=false;
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/PhysicsEngine.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  PhysicsEngine.mqh - SECTION 2: Core Physics Engine              |
//|                                                                  |
//|  Faithful port of f_phys(), which the source computes on the     |
//|  FIXED M5 timeframe so all downstream physics-derived scores are |
//|  timeframe independent. Advanced one CLOSED M5 bar at a time.    |
//|                                                                  |
//|    vel = ema(close-close[1], 3)                                  |
//|    acc = vel - vel[1]                                            |
//|    cvx = acc - acc[1]                                            |
//|    csm = ema(cvx, 3)                                             |
//|    eff = |close-close[effL]| / sum(|close-close[1]|, effL)       |
//|    dsp = (high-low) / atr                                        |
//|                                                                  |
//|  Plus the chart volatility regime derived from atr:              |
//|    volRatio = atr / sma(atr,20) ; volMult = clamp(volRatio,.5,2.5)|
//+------------------------------------------------------------------+

//================= GLOBAL PHYSICS OUTPUTS (Pine names) =============
double atr              = PINE_NA;
double velocity         = 0.0;
double acceleration     = 0.0;
double convexity        = 0.0;
double convSmooth       = 0.0;
double efficiency       = 0.0;
double displacement     = 0.0;
double convThreshold    = 0.0;

bool   bullConvShift    = false;
bool   bearConvShift    = false;
bool   bullImpulse      = false;
bool   bearImpulse      = false;
bool   bullMomDecay     = false;
bool   bearMomDecay     = false;
bool   bullMicroImpulse = false;
bool   bearMicroImpulse = false;
bool   phys_vd70        = false;
bool   phys_vd50        = false;
bool   phys_vd85        = false;
bool   phys_vd55x3      = false;
double phys_mom         = 0.0;
bool   phys_accDec      = false;

//--- chart volatility regime (Section 2 tail)
double phys_volRatio    = 1.0;
double phys_volMult     = 1.0;
string phys_volRegime   = "NORMAL";
bool   phys_ready       = false;

//==================================================================
//| CPhysM5 - stateful M5 physics state machine                     |
//==================================================================
class CPhysM5
  {
private:
   CRma              m_atr;        // ta.atr
   CEma              m_velEma;     // ema(close-close[1],3)
   CEma              m_csmEma;     // ema(cvx,3)
   CSma              m_atrSma;     // sma(atr,20)
   CRing             m_close;      // close history (for close[effL])
   CRing             m_absdiff;    // |close-close[1]| history
   CRing             m_vel;        // velocity history (vel[1], vel[3])
   CRing             m_acc;        // acceleration history (acc[1])
   CRing             m_csm;        // convSmooth history (csm[1])
   double            m_prevClose;
   bool              m_havePrev;
public:
   void              Init()
     {
      m_atr.Init(cfg_atrLen);
      m_velEma.Init(3);
      m_csmEma.Init(3);
      m_atrSma.Init(20);
      m_close.Init(cfg_effLen+4);
      m_absdiff.Init(cfg_effLen+4);
      m_vel.Init(8);
      m_acc.Init(8);
      m_csm.Init(8);
      m_prevClose = PINE_NA;
      m_havePrev  = false;
     }

   //--- feed one closed M5 bar
   void              Update(const double o,const double h,const double l,const double c)
     {
      //--- true range / atr
      double tr;
      if(!m_havePrev) tr = h-l;
      else            tr = MathMax(h-l, MathMax(MathAbs(h-m_prevClose), MathAbs(l-m_prevClose)));
      double _atr = m_atr.Update(tr);

      //--- velocity = ema(close - close[1], 3)
      double dc = m_havePrev ? (c - m_prevClose) : 0.0;
      double _vel = m_velEma.Update(dc);

      double velPrev  = m_vel.Has(0) ? m_vel.Get(0) : _vel;   // becomes vel[1] after push
      double _acc = _vel - velPrev;
      double accPrev  = m_acc.Has(0) ? m_acc.Get(0) : _acc;   // becomes acc[1] after push
      double _cvx = _acc - accPrev;
      double _csm = m_csmEma.Update(_cvx);
      double csmPrev  = m_csm.Has(0) ? m_csm.Get(0) : _csm;   // becomes csm[1] after push

      //--- efficiency
      double _eff = 0.0;
      //--- push close first so history aligns, then read close[effL]
      m_close.Push(c);
      m_absdiff.Push(MathAbs(dc));
      if(m_close.Has(cfg_effLen))
        {
         double cEffL = m_close.Get(cfg_effLen);
         double mv = MathAbs(c - cEffL);
         double ps = m_absdiff.Sum(cfg_effLen);
         _eff = (ps>0.0) ? mv/ps : 0.0;
        }

      double atrSafe = MathMax(IsNa(_atr)?0.0:_atr, 1e-10);
      double _dsp = (h-l)/atrSafe;
      double _cth = (IsNa(_atr)?0.0:_atr) * cfg_convMult;

      double effT  = cfg_effThresh;
      double dispT = cfg_dispThresh;

      //--- convexity shift (csm crossing +/- threshold)
      bool _bCS = (_csm >  _cth) && (csmPrev <=  _cth);
      bool _rCS = (_csm < -_cth) && (csmPrev >= -_cth);

      bool _bImp = (_eff>effT) && (_vel>velPrev) && (_acc>0) && (c>o) && (_dsp>dispT);
      bool _rImp = (_eff>effT) && (_vel<velPrev) && (_acc<0) && (c<o) && (_dsp>dispT);
      bool _bDec = (MathAbs(_acc) < MathAbs(accPrev)*0.8) && (_vel>0);
      bool _rDec = (MathAbs(_acc) < MathAbs(accPrev)*0.8) && (_vel<0);
      bool _bMic = (_eff>effT*0.80) && (_vel>velPrev) && (_acc>0) && (c>o) && (_dsp>dispT*0.50);
      bool _rMic = (_eff>effT*0.80) && (_vel<velPrev) && (_acc<0) && (c<o) && (_dsp>dispT*0.50);

      double velAbsPrev = MathAbs(velPrev);
      bool _vd70 = MathAbs(_vel) < velAbsPrev*0.70;
      bool _vd50 = MathAbs(_vel) < velAbsPrev*0.50;
      bool _vd85 = MathAbs(_vel) < velAbsPrev*0.85;
      double vel3 = m_vel.Has(2) ? m_vel.Get(2) : velPrev;   // vel[3] (after push, current is [0])
      bool _vd55x3 = MathAbs(_vel) < MathAbs(vel3)*0.55;
      double _mom = _vel - velPrev;
      bool _accDec = MathAbs(_acc) < MathAbs(accPrev);

      //--- commit history
      m_vel.Push(_vel);
      m_acc.Push(_acc);
      m_csm.Push(_csm);
      m_prevClose = c;
      m_havePrev  = true;

      //--- atr sma + vol regime (Section 2 tail; updated per M5 bar)
      double _atrSma = m_atrSma.Update(IsNa(_atr)?0.0:_atr);
      double vr = (IsNa(_atrSma)||_atrSma<=0.0) ? 1.0 : (IsNa(_atr)?0.0:_atr)/MathMax(_atrSma,1e-10);

      //--- publish globals
      atr           = _atr;
      velocity      = _vel;
      acceleration  = _acc;
      convexity     = _cvx;
      convSmooth    = _csm;
      efficiency    = _eff;
      displacement  = _dsp;
      convThreshold = _cth;
      bullConvShift = _bCS; bearConvShift = _rCS;
      bullImpulse   = _bImp; bearImpulse   = _rImp;
      bullMomDecay  = _bDec; bearMomDecay  = _rDec;
      bullMicroImpulse = _bMic; bearMicroImpulse = _rMic;
      phys_vd70 = _vd70; phys_vd50 = _vd50; phys_vd85 = _vd85; phys_vd55x3 = _vd55x3;
      phys_mom  = _mom;  phys_accDec = _accDec;

      phys_volRatio  = vr;
      phys_volMult   = Clamp(vr, 0.5, 2.5);
      phys_volRegime = (vr>1.5) ? "HIGH" : (vr<0.7 ? "LOW" : "NORMAL");
      phys_ready     = m_atr.Ready() && m_close.Has(cfg_effLen);
     }

   datetime          lastOpen;
  };

CPhysM5 g_phys;

//==================================================================
void Phys_Init()
  {
   g_phys.Init();
   g_phys.lastOpen = 0;
   phys_ready = false;
  }

//==================================================================
//  Feed all closed M5 bars up to `moment`
//==================================================================
void Phys_Feed(const datetime moment)
  {
   ENUM_TIMEFRAMES tf = g_ladderTF[2];   // canonical rung (M5 at/below H1)
   int shifts[];
   int n = Ctx_PendingBars(tf, g_phys.lastOpen, moment, shifts);
   for(int i=0;i<n;i++)
     {
      int s = shifts[i];
      double o=iOpen(_Symbol,tf,s);
      double h=iHigh(_Symbol,tf,s);
      double l=iLow (_Symbol,tf,s);
      double c=iClose(_Symbol,tf,s);
      if(o==0&&h==0&&l==0&&c==0) continue;
      g_phys.Update(o,h,l,c);
      g_phys.lastOpen = iTime(_Symbol,tf,s);
     }
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/StructureEngine.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  StructureEngine.mqh - the fixed-timeframe structure engine      |
//|                       (V60 14-PHASE upgrade)                     |
//|                                                                  |
//|  Port of f_se(): a self-contained structure state machine that   |
//|  computes (using ONLY its own timeframe series): physics,        |
//|  swings, pivot memory, BOS/CHoCH, impulse, direction + Point4 /  |
//|  invalidation / target, and the V60 14-phase lifecycle driven    |
//|  by a COMPRESSION INDEX, RECURSIVE-TRANSITION counting and       |
//|  DOMINANCE TRANSFER. It models how a move dies and hands off:    |
//|    Expansion -> Pre-Convexity -> Induction -> Liquidity ->       |
//|    New High/Low -> Transition -> Retracement -> HTF Flip Zone -> |
//|    Induction -> Liquidation -> Terminal Curve -> Return.         |
//|                                                                  |
//|  DIR-FIX: the order block is ordered by ACTUAL price (hi/lo),    |
//|  and invalidation is pinned to the protective extreme (zone low  |
//|  for longs, zone high for shorts) so a flip/CHoCH spawn can no    |
//|  longer invert the wave-direction stack.                         |
//|                                                                  |
//|  Six instances run on the adaptive timeframe ladder. The live    |
//|  direction of each layer is recomputed against the chart close   |
//|  (origin-based), then aggregated into the fractal stack and      |
//|  Engine 1A phase authority.                                      |
//+------------------------------------------------------------------+

//================= ENGINE-1A / LAYER GLOBALS ======================
int    m1_dir=0, l3_dir=0, l0_dir=0, l1_dir=0, l2_dir=0, l4_dir=0;
double l0_p4High=PINE_NA, l0_p4Low=PINE_NA, l0_inv=PINE_NA, se5_tgt=PINE_NA;
double se5_mf=0.0, se5_wp=0.0;
string l0_phaseCanon="Point 4 Origin";
string ie1a_currentPhase="Point 4 Origin";
string ie1a_hypFamily="EXPANSION";
double ie1a_phaseConfidence=20.0;
bool   ie1a_isExpSide=true;
int    fractalStackDir=0;
double fractalStackScore=0.0;
double fractalCtxScore=0.0;
int    liveWaveDir=0;
int    liveHtfAlign=0;

//--- V60 extras + per-rung exports (consumed by CurveLife / TimeIntel / Trade)
double se5_comp=0.0, se5_rec=0.0, se5_dom=0.0;
double se5_inv=PINE_NA, se5_sh=PINE_NA, se5_sl=PINE_NA, se5_ft=PINE_NA, se5_fb=PINE_NA;
double se15_tgt=PINE_NA;
double se60_inv=PINE_NA, se60_sh=PINE_NA, se60_sl=PINE_NA, se60_ft=PINE_NA, se60_fb=PINE_NA, se60_tgt=PINE_NA, se60_wp=0.0, se60_comp=0.0;
double se240_inv=PINE_NA, se240_sh=PINE_NA, se240_sl=PINE_NA, se240_ft=PINE_NA, se240_fb=PINE_NA, se240_tgt=PINE_NA, se240_wp=0.0, se240_comp=0.0;
int    se60_phCode=0, se240_phCode=0;

//--- full per-rung curve state (for the multi-timeframe ownership engine)
double se1_wp=0.0,  se1_comp=0.0,  se1_rec=0.0,  se1_dom=0.0;
double se3_wp=0.0,  se3_comp=0.0,  se3_rec=0.0,  se3_dom=0.0;
double se15_wp=0.0, se15_comp=0.0, se15_rec=0.0, se15_dom=0.0;
double se60_rec=0.0, se60_dom=0.0;
double se240_rec=0.0, se240_dom=0.0;

//==================================================================
//  phase code -> canonical lifecycle string (V60 14-phase)
//==================================================================
string PhaseStr(const int c)
  {
   switch(c)
     {
      case 1:  return "Expansion";
      case 2:  return "Expansion Pre-Convexity";
      case 3:  return "Expansion Induction";
      case 4:  return "Expansion Liquidity";
      case 5:  return "New High";
      case 6:  return "New Low";
      case 7:  return "Transition";
      case 8:  return "Retracement";
      case 9:  return "HTF Flip Zone";
      case 10: return "Induction";
      case 11: return "Liquidation";
      case 12: return "Terminal Curve";
      case 13: return "Demand Return";
      case 14: return "Supply Return";
      default: return "Point 4 Origin";
     }
  }

//  canonical phase -> hypothesis family (ie1a_hypFamily)
//  Transition maps to the ABSORPTION family (the move dying / handing off);
//  HTF Flip Zone / Induction / Liquidation / Terminal Curve are the retracement
//  family (counter-trend delivery into the zone).
string HypFamily(const string ph)
  {
   if(ph=="Expansion") return "EXPANSION";
   if(ph=="Expansion Pre-Convexity" || ph=="Expansion Induction" || ph=="Expansion Liquidity") return "CONVEXITY FORMING";
   if(ph=="New High" || ph=="New Low") return "CREATION FORMING";
   if(ph=="Transition") return "ABSORPTION";
   if(ph=="Retracement" || ph=="HTF Flip Zone" || ph=="Induction" || ph=="Liquidation" || ph=="Terminal Curve") return "RETRACEMENT";
   if(ph=="Demand Return" || ph=="Supply Return") return "DEMAND/SUPPLY RETURN";
   return "EXPANSION";
  }

bool PhaseIsExpSide(const string ph)
  {
   return(ph=="Expansion" || ph=="Expansion Pre-Convexity" || ph=="Expansion Induction" ||
          ph=="Expansion Liquidity" || ph=="New High" || ph=="New Low");
  }

//  short phase-family label (multi-timeframe panels / curve map)
string PhaseFamS(const string p)
  {
   if(StringFind(p,"Transition")>=0)   return "Transition";
   if(StringFind(p,"Terminal")>=0)     return "Terminal";
   if(StringFind(p,"Liquidation")>=0)  return "Liquidation";
   if(StringFind(p,"HTF Flip")>=0)     return "Flip Zone";
   if(StringFind(p,"Induction")>=0 && StringFind(p,"Expansion")<0) return "Induction";
   if(StringFind(p,"Pre-Convexity")>=0) return "Pre-Conv";
   if(StringFind(p,"Expansion Induction")>=0) return "Induction";
   if(StringFind(p,"Liquidity")>=0)    return "Liquidity";
   if(StringFind(p,"New High")>=0 || StringFind(p,"New Low")>=0) return "Creation";
   if(StringFind(p,"Return")>=0)       return "Return";
   if(StringFind(p,"Retracement")>=0)  return "Retracement";
   return "Expansion";
  }

//==================================================================
//| CStructEngine - one f_se instance (V60 14-phase)               |
//==================================================================
class CStructEngine
  {
private:
   //--- physics state
   CRma   m_atr;
   CEma   m_velEma, m_csmEma;
   CRing  m_close, m_absdiff;
   double m_velPrev, m_accPrev;
   bool   m_havePrev;
   double m_prevClose;
   //--- pivot detection rings
   CRing  m_hi, m_lo;
   //--- swing state
   double m_curSH, m_curSL, m_prSH, m_prSL;
   //--- pivot memory
   double m_lastP, m_prevP;
   int    m_lastD, m_prevD;
   //--- direction / point4 / invalidation / target
   int    m_dir;
   double m_ft, m_fb, m_p4h, m_p4l, m_inv, m_tgt, m_cycH, m_cycL;
   //--- lifecycle
   bool   m_bos1, m_bos2;
   double m_protSw, m_protSw2, m_indOrig, m_indExt;
   bool   m_indBrk;
   int    m_lastDirSeen;
   int    m_pst;            // 0..13 single-latch phase state
   //--- recursive transition
   int    m_recBrk;
   bool   m_recArm;
public:
   //--- outputs (se*_*)
   int    oDir, oPh, oBos, oCh, oRec;
   double oSH, oSL, oPSH, oPSL, oP4h, oP4l, oInv, oTgt, oFt, oFb, oFs, oWp, oCm, oMf, oComp, oDom;
   datetime lastOpen;

   void   Init()
     {
      m_atr.Init(cfg_atrLen);
      m_velEma.Init(3);
      m_csmEma.Init(3);
      m_close.Init(cfg_effLen+4);
      m_absdiff.Init(cfg_effLen+4);
      m_velPrev=0; m_accPrev=0; m_havePrev=false; m_prevClose=PINE_NA;
      int pcap = 2*cfg_pivotLen+4;
      m_hi.Init(pcap); m_lo.Init(pcap);
      m_curSH=PINE_NA; m_curSL=PINE_NA; m_prSH=PINE_NA; m_prSL=PINE_NA;
      m_lastP=PINE_NA; m_prevP=PINE_NA; m_lastD=0; m_prevD=0;
      m_dir=0; m_ft=PINE_NA; m_fb=PINE_NA; m_p4h=PINE_NA; m_p4l=PINE_NA;
      m_inv=PINE_NA; m_tgt=PINE_NA; m_cycH=PINE_NA; m_cycL=PINE_NA;
      m_bos1=false; m_bos2=false; m_protSw=PINE_NA; m_protSw2=PINE_NA;
      m_indOrig=PINE_NA; m_indExt=PINE_NA; m_indBrk=false; m_lastDirSeen=0; m_pst=0;
      m_recBrk=0; m_recArm=true;
      oDir=0; oPh=0; oBos=0; oCh=0; oRec=0;
      oSH=PINE_NA; oSL=PINE_NA; oPSH=PINE_NA; oPSL=PINE_NA;
      oP4h=PINE_NA; oP4l=PINE_NA; oInv=PINE_NA; oTgt=PINE_NA; oFt=PINE_NA; oFb=PINE_NA;
      oFs=0; oWp=0; oCm=0; oMf=0; oComp=0; oDom=0; lastOpen=0;
     }

   void   Update(const double o,const double h,const double l,const double c)
     {
      double effT=cfg_effThresh, dispT=cfg_dispThresh, convM=cfg_convMult, impM=cfg_impulseAtrMult, chBuf=cfg_chochBufferATR;

      //---- PHYSICS (this tf) ----
      double tr = (!m_havePrev)?(h-l):MathMax(h-l,MathMax(MathAbs(h-m_prevClose),MathAbs(l-m_prevClose)));
      double _atr=m_atr.Update(tr);
      double atrv=IsNa(_atr)?0.0:_atr;
      double dc = m_havePrev?(c-m_prevClose):0.0;
      double _vel=m_velEma.Update(dc);
      double _acc=_vel-m_velPrev;
      double _conv=_acc-m_accPrev;
      double _csm=m_csmEma.Update(_conv);
      m_close.Push(c); m_absdiff.Push(MathAbs(dc));
      double _eff=0.0;
      if(m_close.Has(cfg_effLen))
        {
         double cO=m_close.Get(cfg_effLen);
         double ps=m_absdiff.Sum(cfg_effLen);
         _eff=(ps>0.0)?MathAbs(c-cO)/ps:0.0;
        }
      double _disp=(h-l)/MathMax(atrv,1e-10);
      bool _bullImp=(_eff>effT)&&(_vel>m_velPrev)&&(_acc>0)&&(c>o)&&(_disp>dispT);
      bool _bearImp=(_eff>effT)&&(_vel<m_velPrev)&&(_acc<0)&&(c<o)&&(_disp>dispT);
      bool _bullDec=(MathAbs(_acc)<MathAbs(m_accPrev)*0.8)&&(_vel>0);
      bool _bearDec=(MathAbs(_acc)<MathAbs(m_accPrev)*0.8)&&(_vel<0);
      double velPrevAbs=MathAbs(m_velPrev);

      //---- SWINGS ----
      m_hi.Push(h); m_lo.Push(l);
      double _pH=PivotHigh(m_hi, cfg_pivotLen);
      double _pL=PivotLow (m_lo, cfg_pivotLen);
      if(!IsNa(_pH)){ m_prSH = IsNa(m_curSH)?_pH:m_curSH; m_curSH=_pH; }
      if(!IsNa(_pL)){ m_prSL = IsNa(m_curSL)?_pL:m_curSL; m_curSL=_pL; }

      //---- PIVOT MEMORY ----
      double _eP=PINE_NA; int _eD=0;
      if(!IsNa(_pH)){ _eP=_pH; _eD=1; }
      else if(!IsNa(_pL)){ _eP=_pL; _eD=-1; }
      if(_eD!=0){ m_prevP=m_lastP; m_prevD=m_lastD; m_lastP=_eP; m_lastD=_eD; }

      //---- BOS / CHoCH ----
      bool _bullBOS=(!IsNa(m_prSH))&&(c>m_prSH);
      bool _bearBOS=(!IsNa(m_prSL))&&(c<m_prSL);
      bool _bullCH =(!IsNa(m_prSH))&&(c>m_prSH+atrv*chBuf);
      bool _bearCH =(!IsNa(m_prSL))&&(c<m_prSL-atrv*chBuf);

      //---- IMPULSE ----
      bool _eLong =(!IsNa(_pH))&&(m_prevD==-1)&&(!IsNa(m_prevP))&&((_pH-m_prevP)>atrv*impM);
      bool _eShort=(!IsNa(_pL))&&(m_prevD==1 )&&(!IsNa(m_prevP))&&((m_prevP-_pL)>atrv*impM);

      //---- DIRECTION / POINT4 / INVALIDATION / TARGET (DIR-FIX) ----
      bool _hasCtx=(m_dir!=0)&&(!IsNa(m_ft));
      bool _flipDn=(m_dir==1)&&_bearCH;
      bool _flipUp=(m_dir==-1)&&_bullCH;
      bool _isRev =(_eLong&&m_dir==-1)||(_eShort&&m_dir==1)||_flipUp||_flipDn;
      bool _spawn =(_eLong||_eShort||_flipUp||_flipDn)&&(!_hasCtx||_isRev);
      if(_spawn)
        {
         int _nd=_eLong?1:_eShort?-1:_flipUp?1:-1;
         //--- order the order-block by ACTUAL price, not pivot recency.
         double _hi=MathMax(m_lastP,m_prevP);
         double _lo=MathMin(m_lastP,m_prevP);
         m_dir=_nd; m_ft=_hi; m_fb=_lo; m_p4h=_hi; m_p4l=_lo; m_cycH=h; m_cycL=l;
         //--- invalidation pinned to the protective extreme.
         m_inv=(_nd==1)?_lo:_hi;
         double _rng=(!IsNa(m_prSH)&&!IsNa(m_prSL))?MathAbs(m_prSH-m_prSL):atrv*5.0;
         m_tgt=(_nd==1)?Nz(m_ft,c)+_rng:Nz(m_fb,c)-_rng;
        }
      if(m_dir==1)  m_cycH=IsNa(m_cycH)?h:MathMax(m_cycH,h);
      if(m_dir==-1) m_cycL=IsNa(m_cycL)?l:MathMin(m_cycL,l);
      int _bosOut=_bullBOS?1:_bearBOS?-1:0;
      int _chOut =_bullCH ?1:_bearCH ?-1:0;

      //---- LIFECYCLE STRUCTURE (BOS1/BOS2/induction) ----
      bool _reset=(m_dir!=m_lastDirSeen);
      m_lastDirSeen=m_dir;
      if(_reset){ m_bos1=false; m_bos2=false; m_protSw=PINE_NA; m_protSw2=PINE_NA; m_indOrig=PINE_NA; m_indExt=PINE_NA; m_indBrk=false; }
      if(m_dir==1 && !IsNa(_pL)){ m_protSw2=m_protSw; m_protSw=_pL; }
      if(m_dir==-1 && !IsNa(_pH)){ m_protSw2=m_protSw; m_protSw=_pH; }
      bool _oppBOS=(m_dir==1 && !IsNa(m_protSw) && c<m_protSw)||(m_dir==-1 && !IsNa(m_protSw) && c>m_protSw);
      if(!m_bos1 && _oppBOS){ m_bos1=true; m_indOrig=(m_dir==1)?Nz(m_cycH,h):Nz(m_cycL,l); }
      if(m_bos1 && !m_bos2 && _oppBOS && !IsNa(m_protSw2) && (m_dir==1?c<m_protSw2:c>m_protSw2)) m_bos2=true;
      if(m_bos1 && m_dir==1)  m_indExt=IsNa(m_indExt)?c:MathMin(m_indExt,c);
      if(m_bos1 && m_dir==-1) m_indExt=IsNa(m_indExt)?c:MathMax(m_indExt,c);
      if(m_bos2 && !IsNa(m_indOrig))
        {
         if(m_dir==1 && c>m_indOrig) m_indBrk=true;
         if(m_dir==-1 && c<m_indOrig) m_indBrk=true;
        }

      //---- SCORES ----
      double _convScore=PineMin(MathAbs(_csm)/MathMax(atrv*convM,1e-10)*50.0,100.0);
      double _expScore =PineMin(_eff/MathMax(effT,1e-10)*50.0+_disp/MathMax(dispT,1e-10)*50.0,100.0);
      double _absScore =(_eff<effT*0.7 && MathAbs(_vel)<velPrevAbs*0.6) ? 60.0+_convScore*0.4 : _convScore*0.3;
      bool _momExpStrong=(_eff>effT*0.75)&&(m_dir==1?_vel>0:_vel<0);
      bool _momDecaying =(m_dir==1)?_bullDec:_bearDec;
      bool _momCounter  =(m_dir==1)?_bearImp:_bullImp;
      bool _momExhaust  =(_eff<effT*0.65)&&(_absScore>40.0);
      bool _physConvexDevel=_convScore>35.0;
      bool _physTransfer   =_convScore>48.0||_absScore>40.0;
      bool _physCapacityLow=_absScore>45.0||_eff<effT*0.6;

      //---- DIRECTION (origin-based) + geometry ----
      int   _wdir   = (!IsNa(m_inv)) ? (c>m_inv?1:(c<m_inv?-1:m_dir)) : m_dir;
      bool  _atFlip = (!IsNa(m_ft)&&!IsNa(m_fb)&&c<=m_ft&&c>=m_fb);
      bool  _expanding = _momExpStrong||_eLong||_eShort||(_wdir==1?_bullImp:_bearImp);
      bool  _atExtreme = _wdir==1 ? (h>=Nz(m_cycH,h)) : _wdir==-1 ? (l<=Nz(m_cycL,l)) : false;
      double _extr   = _wdir==1 ? Nz(m_cycH,c) : Nz(m_cycL,c);
      bool  _extended = (!IsNa(m_inv)) && (MathAbs(_extr-m_inv)>atrv*1.5);
      double _fzMid  = (!IsNa(m_ft)&&!IsNa(m_fb)) ? (m_ft+m_fb)/2.0 : PINE_NA;
      double _retrFrac = (!IsNa(_fzMid)&&MathAbs(_extr-_fzMid)>1e-10) ? MathAbs(_extr-c)/MathAbs(_extr-_fzMid) : 0.0;
      //--- COMPRESSION INDEX (0..100): high when displacement & efficiency are LOW
      double _compIdx = Clamp((1.0-PineMin(_disp/MathMax(dispT,1e-10),1.0))*60.0 + (1.0-PineMin(_eff/MathMax(effT,1e-10),1.0))*40.0, 0.0, 100.0);

      //---- RECURSIVE TRANSITION + DOMINANCE TRANSFER ----
      bool _phase2CH = (m_dir==1 && _bearCH)||(m_dir==-1 && _bullCH);
      if(_reset || (_atExtreme && _extended)){ m_recBrk=0; m_recArm=true; }
      if((m_dir==1 && !IsNa(_pH))||(m_dir==-1 && !IsNa(_pL))) m_recArm=true;
      if((_phase2CH||_oppBOS) && m_recArm && !_atExtreme){ m_recBrk=m_recBrk+1; m_recArm=false; }
      double _recDom = PineMin(MathMax(m_recBrk*(30.0-_compIdx*0.15), _retrFrac*80.0), 100.0);
      bool   _transferDone = _recDom>=50.0;

      //---- SINGLE-LATCH PHASE STATE MACHINE (0 -> 13) ----
      if(_reset) m_pst=0;
      if(m_dir!=0 && !_reset)
        {
         if(m_pst==0 && _expanding) m_pst=1;
         if(m_pst==1 && !_atExtreme && _momDecaying && _physConvexDevel) m_pst=2;
         if(m_pst==2 && !_atExtreme && _momCounter && _physTransfer) m_pst=3;
         if(m_pst==3 && !_atExtreme && (m_bos1||m_bos2||m_indBrk) && _physTransfer) m_pst=4;
         if(m_pst>=1 && m_pst<=7 && _atExtreme && _extended) m_pst=5;
         if(m_pst==5 && !_atExtreme && (m_recBrk>=1 || _momExhaust)) m_pst=7;
         if(m_pst==7 && _transferDone) m_pst=8;
         if(m_pst==8 && _atFlip) m_pst=9;
         if(m_pst==9 && ((m_dir==1 && _bullImp)||(m_dir==-1 && _bearImp))) m_pst=10;
         if(m_pst==10 && (_oppBOS || _physCapacityLow)) m_pst=11;
         if(m_pst==11 && ((m_dir==1 && l<m_fb)||(m_dir==-1 && h>m_ft))) m_pst=12;
         if(m_pst==12 && ((m_dir==1 && _bullCH)||(m_dir==-1 && _bearCH))) m_pst=13;
        }
      int _phase=m_pst;
      if(_phase==5 && m_dir==-1) _phase=6;
      if(_phase==13 && m_dir==-1) _phase=14;

      double _wp = m_pst==0?5.0:m_pst==1?15.0:m_pst==2?25.0:m_pst==3?33.0:m_pst==4?42.0:m_pst==5?55.0:m_pst==7?65.0:m_pst==8?75.0:m_pst==9?85.0:m_pst==10?90.0:m_pst==11?94.0:m_pst==12?97.0:100.0;
      double _cm = PineMin(_convScore,100.0);
      double _mf = PineMin(MathMax(_expScore,MathMax(_absScore,_convScore))*0.70+(m_dir!=0?30.0:0.0),100.0);
      double _frzS=PineMin((_eLong||_eShort?50.0:0.0)+_expScore*0.30+_convScore*0.20,100.0);
      int _dirLabel = _wdir;

      //---- publish outputs ----
      oDir=_dirLabel; oPh=_phase; oSH=m_curSH; oSL=m_curSL; oPSH=m_prSH; oPSL=m_prSL;
      oBos=_bosOut; oCh=_chOut; oP4h=m_p4h; oP4l=m_p4l; oInv=m_inv; oTgt=m_tgt;
      oFt=m_ft; oFb=m_fb; oFs=_frzS; oWp=_wp; oCm=_cm; oMf=_mf;
      oComp=_compIdx; oRec=m_recBrk; oDom=_recDom;

      //---- commit physics state ----
      m_velPrev=_vel; m_accPrev=_acc; m_prevClose=c; m_havePrev=true;
     }
  };

CStructEngine g_se1, g_se3, g_se5, g_se15, g_se60, g_se240;

//==================================================================
void Struct_InitAll()
  {
   g_se1.Init(); g_se3.Init(); g_se5.Init(); g_se15.Init(); g_se60.Init(); g_se240.Init();
  }

void Struct_FeedEngine(CStructEngine &eng,const ENUM_TIMEFRAMES tf,const datetime moment)
  {
   int shifts[];
   int n=Ctx_PendingBars(tf, eng.lastOpen, moment, shifts);
   for(int i=0;i<n;i++)
     {
      int s=shifts[i];
      double o=iOpen(_Symbol,tf,s),h=iHigh(_Symbol,tf,s),l=iLow(_Symbol,tf,s),c=iClose(_Symbol,tf,s);
      if(o==0&&h==0&&l==0&&c==0) continue;
      eng.Update(o,h,l,c);
      eng.lastOpen=iTime(_Symbol,tf,s);
     }
  }

void Struct_FeedAll(const datetime moment)
  {
   //--- adaptive ladder (Part B): g_ladderTF[] computed in Context
   Struct_FeedEngine(g_se1,  g_ladderTF[0], moment);
   Struct_FeedEngine(g_se3,  g_ladderTF[1], moment);
   Struct_FeedEngine(g_se5,  g_ladderTF[2], moment);
   Struct_FeedEngine(g_se15, g_ladderTF[3], moment);
   Struct_FeedEngine(g_se60, g_ladderTF[4], moment);
   Struct_FeedEngine(g_se240,g_ladderTF[5], moment);
  }

//==================================================================
//  f_waveDirByOrigin against the live chart close
//==================================================================
int WaveDirByOrigin(const double origin,const int fallback)
  {
   double cl=C_close();
   if(IsNa(origin) || IsNa(cl)) return fallback;
   if(cl>origin) return 1;
   if(cl<origin) return -1;
   return fallback;
  }

//==================================================================
//  Live derivation: layer dirs, fractal stack, Engine 1A, exports
//==================================================================
void Struct_DeriveLive()
  {
   m1_dir = WaveDirByOrigin(g_se1.oInv,   g_se1.oDir);
   l3_dir = WaveDirByOrigin(g_se3.oInv,   g_se3.oDir);
   l0_dir = WaveDirByOrigin(g_se5.oInv,   g_se5.oDir);
   l1_dir = WaveDirByOrigin(g_se15.oInv,  g_se15.oDir);
   l2_dir = WaveDirByOrigin(g_se60.oInv,  g_se60.oDir);
   l4_dir = WaveDirByOrigin(g_se240.oInv, g_se240.oDir);

   l0_p4High = g_se5.oP4h;
   l0_p4Low  = g_se5.oP4l;
   l0_inv    = g_se5.oInv;
   se5_tgt   = g_se5.oTgt;
   se5_mf    = g_se5.oMf;
   se5_wp    = g_se5.oWp;

   //--- V60 extras + per-rung exports
   se5_comp=g_se5.oComp; se5_rec=g_se5.oRec; se5_dom=g_se5.oDom;
   se5_inv=g_se5.oInv; se5_sh=g_se5.oSH; se5_sl=g_se5.oSL; se5_ft=g_se5.oFt; se5_fb=g_se5.oFb;
   se15_tgt=g_se15.oTgt;
   se60_inv=g_se60.oInv; se60_sh=g_se60.oSH; se60_sl=g_se60.oSL; se60_ft=g_se60.oFt; se60_fb=g_se60.oFb;
   se60_tgt=g_se60.oTgt; se60_wp=g_se60.oWp; se60_comp=g_se60.oComp; se60_phCode=g_se60.oPh;
   se240_inv=g_se240.oInv; se240_sh=g_se240.oSH; se240_sl=g_se240.oSL; se240_ft=g_se240.oFt; se240_fb=g_se240.oFb;
   se240_tgt=g_se240.oTgt; se240_wp=g_se240.oWp; se240_comp=g_se240.oComp; se240_phCode=g_se240.oPh;

   //--- full per-rung curve state
   se1_wp=g_se1.oWp;   se1_comp=g_se1.oComp;   se1_rec=g_se1.oRec;   se1_dom=g_se1.oDom;
   se3_wp=g_se3.oWp;   se3_comp=g_se3.oComp;   se3_rec=g_se3.oRec;   se3_dom=g_se3.oDom;
   se15_wp=g_se15.oWp; se15_comp=g_se15.oComp; se15_rec=g_se15.oRec; se15_dom=g_se15.oDom;
   se60_rec=g_se60.oRec; se60_dom=g_se60.oDom;
   se240_rec=g_se240.oRec; se240_dom=g_se240.oDom;

   l0_phaseCanon = PhaseStr(g_se5.oPh);

   //--- fractal stack
   int sb = (m1_dir==1?1:0)+(l3_dir==1?1:0)+(l0_dir==1?1:0)+(l1_dir==1?1:0)+(l2_dir==1?1:0)+(l4_dir==1?1:0);
   int sr = (m1_dir==-1?1:0)+(l3_dir==-1?1:0)+(l0_dir==-1?1:0)+(l1_dir==-1?1:0)+(l2_dir==-1?1:0)+(l4_dir==-1?1:0);
   fractalStackDir   = sb>sr ? 1 : (sr>sb ? -1 : 0);
   fractalStackScore = (double)MathMax(sb,sr)/6.0*100.0;

   fractalCtxScore = PineMin(
        (l4_dir==fractalStackDir && fractalStackDir!=0 ? 30.0:0.0)+
        (l2_dir==fractalStackDir && fractalStackDir!=0 ? 26.0:0.0)+
        (l1_dir==fractalStackDir && fractalStackDir!=0 ? 20.0:0.0)+
        (l0_dir==fractalStackDir && fractalStackDir!=0 ? 14.0:0.0)+
        (l3_dir==fractalStackDir && fractalStackDir!=0 ?  6.0:0.0)+
        (m1_dir==fractalStackDir && fractalStackDir!=0 ?  4.0:0.0), 100.0);

   liveWaveDir  = l0_dir;
   liveHtfAlign = (l2_dir!=0 && l2_dir==l4_dir) ? l2_dir : 0;

   //--- Engine 1A
   ie1a_currentPhase   = l0_phaseCanon;
   ie1a_phaseConfidence= Clamp(fractalCtxScore*0.50 + se5_mf*0.30 + se5_wp*0.20, 20.0, 100.0);
   ie1a_hypFamily      = HypFamily(ie1a_currentPhase);
   ie1a_isExpSide      = PhaseIsExpSide(ie1a_currentPhase);
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/BeliefEngine.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  BeliefEngine.mqh - SECTION 3: HTF Belief Engine + MTF bias      |
//|                     + SECTION 12I: M1 early-warning physics      |
//|                                                                  |
//|  f_htfBeliefs() is evaluated on tf1 (HTF bias 1) and tf2         |
//|  (HTF bias 2). Each returns a directional read plus expansion /  |
//|  decay / curvature / absorption / liquidity belief scores.       |
//|  htfBias1/2 latch on strong expansion and release on strong      |
//|  decay; htfAlign requires both biases to agree.                  |
//+------------------------------------------------------------------+

//================= GLOBAL OUTPUTS =================================
int    dir_tf1=0, dir_tf2=0;
double expScr_tf1=0, expScr_tf2=0;
double decScr_tf1=0, decScr_tf2=0;
double curvScr_tf1=0, curvScr_tf2=0;
double abScr_tf1=0, abScr_tf2=0;
double liqScr_tf1=0, liqScr_tf2=0;

int    htfBias1=0, htfBias2=0;
int    htfAlign=0;

//--- M1 early warning (Section 12I); some are forward-referenced vars
bool   m1ExpansionWeak=false;
bool   m1ConvexityEmer=false;
bool   m1InductionEmer=false;
bool   m1LiquidityEmer=false;
bool   m1AbsorptionEmer=false;
int    m1WarningScore=0;
string m1Warning="CLEAR";

//==================================================================
//| CHtfBelief - f_htfBeliefs() per HTF                             |
//==================================================================
class CHtfBelief
  {
private:
   CRma              m_atr;
   CEma              m_velEma;
   CEma              m_csmEma;
   CRing             m_close;
   CRing             m_absdiff;
   double            m_velPrev, m_accPrev;
   bool              m_havePrev;
   double            m_prevClose;
public:
   int               outDir;
   double            outExp, outDec, outCurv, outAb, outLiq;
   datetime          lastOpen;

   void              Init()
     {
      m_atr.Init(cfg_atrLen);
      m_velEma.Init(3);
      m_csmEma.Init(3);
      m_close.Init(cfg_obLookback+4);
      m_absdiff.Init(cfg_obLookback+4);
      m_velPrev=0; m_accPrev=0; m_havePrev=false; m_prevClose=PINE_NA;
      outDir=0; outExp=0; outDec=0; outCurv=0; outAb=0; outLiq=0; lastOpen=0;
     }

   void              Update(const double o,const double h,const double l,const double c)
     {
      double tr = (!m_havePrev) ? (h-l) : MathMax(h-l, MathMax(MathAbs(h-m_prevClose),MathAbs(l-m_prevClose)));
      double _atr = m_atr.Update(tr);
      double dc   = m_havePrev ? (c-m_prevClose) : 0.0;
      double _vel = m_velEma.Update(dc);
      double _acc = _vel - m_velPrev;
      double _conv= _acc - m_accPrev;
      double _csm = m_csmEma.Update(_conv);
      double _convTh = (IsNa(_atr)?0.0:_atr)*cfg_convMult;

      m_close.Push(c);
      m_absdiff.Push(MathAbs(dc));
      double _eff=0.0;
      if(m_close.Has(cfg_obLookback))
        {
         double cO = m_close.Get(cfg_obLookback);
         double mv = MathAbs(c-cO);
         double ps = m_absdiff.Sum(cfg_obLookback);
         _eff = (ps>0.0)? mv/ps : 0.0;
        }
      double atrSafe = MathMax(IsNa(_atr)?0.0:_atr,1e-10);
      double _disp = (h-l)/atrSafe;
      double effT=cfg_effThresh, dispT=cfg_dispThresh;
      double convThSafe = MathMax(_convTh,1e-10);

      double _expScore = PineMin(_eff/MathMax(effT,1e-10)*50.0 + _disp/MathMax(dispT,1e-10)*50.0, 100.0);
      double _decayScr = (MathAbs(_acc) < MathAbs(m_accPrev)*0.8) ? PineMin(MathAbs(_conv)/convThSafe*50.0,100.0) : 0.0;
      double _curvScr  = PineMin(MathAbs(_csm)/convThSafe*50.0,100.0);
      double _abScr    = (_eff<effT*0.7 && MathAbs(_vel)<MathAbs(m_velPrev)*0.6) ? 60.0+_curvScr*0.4 : _curvScr*0.3;
      double _liqScr   = (MathAbs(_csm)>_convTh*1.5 && _disp>dispT) ? PineMin(_curvScr*1.2,100.0) : _curvScr*0.5;

      bool _bullImp = (_eff>effT)&&(_vel>m_velPrev)&&(_acc>0)&&(c>o)&&(_disp>dispT);
      bool _bearImp = (_eff>effT)&&(_vel<m_velPrev)&&(_acc<0)&&(c<o)&&(_disp>dispT);
      int  _dir = _bullImp?1:_bearImp?-1:0;

      outDir=_dir; outExp=_expScore; outDec=_decayScr; outCurv=_curvScr; outAb=_abScr; outLiq=_liqScr;

      m_velPrev=_vel; m_accPrev=_acc; m_prevClose=c; m_havePrev=true;
     }
  };

//==================================================================
//| CM1Phys - f_m1Physics() early-warning on M1                     |
//==================================================================
class CM1Phys
  {
private:
   CRma              m_atr;
   CEma              m_velEma;
   CRing             m_close;
   CRing             m_absdiff;
   double            m_velPrev, m_accPrev;
   bool              m_havePrev;
   double            m_prevClose;
public:
   bool              oExpWeak,oConvEmer,oIndEmer,oLiqEmer,oAbsEmer;
   datetime          lastOpen;

   void              Init()
     {
      m_atr.Init(cfg_atrLen);
      m_velEma.Init(3);
      m_close.Init(cfg_effLen+4);
      m_absdiff.Init(cfg_effLen+4);
      m_velPrev=0; m_accPrev=0; m_havePrev=false; m_prevClose=PINE_NA;
      oExpWeak=false;oConvEmer=false;oIndEmer=false;oLiqEmer=false;oAbsEmer=false;lastOpen=0;
     }

   void              Update(const double o,const double h,const double l,const double c)
     {
      double tr = (!m_havePrev)?(h-l):MathMax(h-l,MathMax(MathAbs(h-m_prevClose),MathAbs(l-m_prevClose)));
      double _atr=m_atr.Update(tr);
      double dc = m_havePrev?(c-m_prevClose):0.0;
      double _v = m_velEma.Update(dc);
      double _a = _v - m_velPrev;
      double _cv= _a - m_accPrev;
      m_close.Push(c); m_absdiff.Push(MathAbs(dc));
      double _e=0.0;
      if(m_close.Has(cfg_effLen))
        {
         double cO=m_close.Get(cfg_effLen);
         double mvv=MathAbs(c-cO);
         double ps=m_absdiff.Sum(cfg_effLen);
         _e=(ps>0.0)?mvv/ps:0.0;
        }
      double atrSafe=MathMax(IsNa(_atr)?0.0:_atr,1e-10);
      double _d=(h-l)/atrSafe;
      double atrv = IsNa(_atr)?0.0:_atr;
      bool _mD = MathAbs(_a) < MathAbs(m_accPrev)*0.8;
      oExpWeak = (_e<cfg_effThresh*0.7) && _mD;
      oConvEmer= (MathAbs(_cv)>atrv*cfg_convMult*1.5) && _mD;
      oIndEmer = (_e>cfg_effThresh) && (_a<0) && (_v>0);
      oLiqEmer = (_d>cfg_dispThresh*1.2) && _mD;
      oAbsEmer = (_e<cfg_effThresh*0.5) && (_d<cfg_dispThresh*0.6);
      m_velPrev=_v; m_accPrev=_a; m_prevClose=c; m_havePrev=true;
     }
  };

CHtfBelief g_b1, g_b2;
CM1Phys    g_m1;

//==================================================================
void Belief_Init()
  {
   g_b1.Init();
   g_b2.Init();
   g_m1.Init();
   dir_tf1=0; dir_tf2=0; htfBias1=0; htfBias2=0; htfAlign=0;
  }

//--- feed one engine over its TF's pending closed bars
void Belief_FeedOne(CHtfBelief &eng,const ENUM_TIMEFRAMES tf,const datetime moment)
  {
   int shifts[];
   int n=Ctx_PendingBars(tf, eng.lastOpen, moment, shifts);
   for(int i=0;i<n;i++)
     {
      int s=shifts[i];
      double o=iOpen(_Symbol,tf,s),h=iHigh(_Symbol,tf,s),l=iLow(_Symbol,tf,s),c=iClose(_Symbol,tf,s);
      if(o==0&&h==0&&l==0&&c==0) continue;
      eng.Update(o,h,l,c);
      eng.lastOpen=iTime(_Symbol,tf,s);
     }
  }

void Belief_FeedM1(const datetime moment)
  {
   ENUM_TIMEFRAMES tf = g_ladderTF[0];   // lowest ladder rung (M1 at/below H1)
   int shifts[];
   int n=Ctx_PendingBars(tf, g_m1.lastOpen, moment, shifts);
   for(int i=0;i<n;i++)
     {
      int s=shifts[i];
      double o=iOpen(_Symbol,tf,s),h=iHigh(_Symbol,tf,s),l=iLow(_Symbol,tf,s),c=iClose(_Symbol,tf,s);
      if(o==0&&h==0&&l==0&&c==0) continue;
      g_m1.Update(o,h,l,c);
      g_m1.lastOpen=iTime(_Symbol,tf,s);
     }
  }

void Belief_Feed(const datetime moment)
  {
   Belief_FeedOne(g_b1, cfg_tf1, moment);
   Belief_FeedOne(g_b2, cfg_tf2, moment);
   Belief_FeedM1(moment);
  }

//==================================================================
//  Chart-bar derivation: publish scores, latch biases, m1 warning
//==================================================================
void Belief_DeriveLive()
  {
   dir_tf1=g_b1.outDir; dir_tf2=g_b2.outDir;
   expScr_tf1=g_b1.outExp; expScr_tf2=g_b2.outExp;
   decScr_tf1=g_b1.outDec; decScr_tf2=g_b2.outDec;
   curvScr_tf1=g_b1.outCurv; curvScr_tf2=g_b2.outCurv;
   abScr_tf1=g_b1.outAb; abScr_tf2=g_b2.outAb;
   liqScr_tf1=g_b1.outLiq; liqScr_tf2=g_b2.outLiq;

   //--- latch (Section 3)
   if(expScr_tf1>60 && dir_tf1!=0) htfBias1=dir_tf1;
   if(expScr_tf2>60 && dir_tf2!=0) htfBias2=dir_tf2;
   if(decScr_tf1>70 && dir_tf1==htfBias1) htfBias1=0;
   if(decScr_tf2>70 && dir_tf2==htfBias2) htfBias2=0;

   htfAlign = (htfBias1==1 && htfBias2==1) ? 1 :
              (htfBias1==-1 && htfBias2==-1) ? -1 : 0;

   //--- M1 early warning aggregation
   m1ExpansionWeak = g_m1.oExpWeak;
   m1ConvexityEmer = g_m1.oConvEmer;
   m1InductionEmer = g_m1.oIndEmer;
   m1LiquidityEmer = g_m1.oLiqEmer;
   m1AbsorptionEmer= g_m1.oAbsEmer;
   m1WarningScore  = (m1ExpansionWeak?1:0)+(m1ConvexityEmer?1:0)+(m1InductionEmer?1:0)+(m1LiquidityEmer?1:0)+(m1AbsorptionEmer?1:0);
   m1Warning = m1WarningScore>=4 ? "CRITICAL" : m1WarningScore>=3 ? "HIGH" : m1WarningScore>=2 ? "MODERATE" : m1WarningScore>=1 ? "LOW" : "CLEAR";
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/MarketStructure.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  MarketStructure.mqh - SECTIONS 4-8 (chart context)             |
//|                                                                  |
//|  Section 4  : structure pivots (HH/HL/LH/LL), swing BOS/CHoCH,   |
//|               structBias, structLongOK/structShortOK             |
//|  Section 5  : pivot memory (last/prev pivot price/bar/dir)       |
//|  Section 6  : elite impulse detection                            |
//|  Section 7  : f_findInducPrice (inducement/flipzone finder)      |
//|  Section 8  : wave-context accept-bars range helpers             |
//|                                                                  |
//|  Runs on the working-timeframe series (g_H/g_L/g_C) after the    |
//|  current bar has been pushed; pivots use the same ta.pivot*      |
//|  confirm-at-current-bar semantics as the source.                 |
//+------------------------------------------------------------------+

//================= GLOBAL OUTPUTS =================================
double structPivH=PINE_NA, structPivL=PINE_NA;
double lastPivHigh=PINE_NA, prevPivHigh=PINE_NA, lastPivLow=PINE_NA, prevPivLow=PINE_NA;
int    structBias=0;
bool   isHH=false, isLH=false, isHL=false, isLL=false;

double prevSwingHigh=PINE_NA, prevSwingLow=PINE_NA, currSwingHigh=PINE_NA, currSwingLow=PINE_NA;
bool   bullBOS=false, bearBOS=false, bullCHoCH=false, bearCHoCH=false;
bool   structLongOK=false, structShortOK=false;

double pivH=PINE_NA, pivL=PINE_NA;
double lastPivotPrice=PINE_NA, prevPivotPrice=PINE_NA;
long   lastPivotBar=-1, prevPivotBar=-1;
int    lastPivotDir=0, prevPivotDir=0;

bool   eliteShortImpulse=false, eliteLongImpulse=false;

double g_highestAB=PINE_NA, g_lowestAB=PINE_NA;

//==================================================================
void MS_Init()
  {
   structPivH=PINE_NA; structPivL=PINE_NA;
   lastPivHigh=PINE_NA; prevPivHigh=PINE_NA; lastPivLow=PINE_NA; prevPivLow=PINE_NA;
   structBias=0; isHH=false; isLH=false; isHL=false; isLL=false;
   prevSwingHigh=PINE_NA; prevSwingLow=PINE_NA; currSwingHigh=PINE_NA; currSwingLow=PINE_NA;
   bullBOS=false; bearBOS=false; bullCHoCH=false; bearCHoCH=false;
   structLongOK=false; structShortOK=false;
   pivH=PINE_NA; pivL=PINE_NA;
   lastPivotPrice=PINE_NA; prevPivotPrice=PINE_NA; lastPivotBar=-1; prevPivotBar=-1;
   lastPivotDir=0; prevPivotDir=0;
   eliteShortImpulse=false; eliteLongImpulse=false;
  }

//==================================================================
//  Section 7: f_findInducPrice
//  Scans i=1..min(lookback, barIndex-anchorRefBar). A qualifying bar
//  has high[i] < top and low[i] > bot. Returns the midpoint of the
//  qualifying bar whose absolute bar-distance to anchorRefBar is
//  smallest; PINE_NA if none.
//==================================================================
double FindInducPrice(const long anchorRefBar,const double top,const double bot,const int lookback)
  {
   if(IsNa(top) || IsNa(bot) || anchorRefBar<0) return PINE_NA;
   long span = g_barIndex - anchorRefBar;
   int maxI = (int)MathMin((long)lookback, span);
   double best=PINE_NA, bestDist=PINE_NA;
   for(int i=1;i<=maxI;i++)
     {
      double hi=g_H.Get(i), lo=g_L.Get(i);
      if(IsNa(hi)||IsNa(lo)) continue;
      if(hi<top && lo>bot)
        {
         double d=MathAbs((double)((g_barIndex-i)-anchorRefBar));
         if(IsNa(bestDist) || d<bestDist){ bestDist=d; best=(hi+lo)/2.0; }
        }
     }
   return best;
  }

//==================================================================
void MS_Compute()
  {
   double cl=C_close();
   double atrv = IsNa(atr)?0.0:atr;

   //==================== SECTION 4 ===============================
   structPivH = PivotHigh(g_H, cfg_structLen);
   structPivL = PivotLow (g_L, cfg_structLen);

   if(!IsNa(structPivH)){ prevPivHigh=lastPivHigh; lastPivHigh=structPivH; }
   if(!IsNa(structPivL)){ prevPivLow =lastPivLow;  lastPivLow =structPivL; }

   isHH = (!IsNa(lastPivHigh)&&!IsNa(prevPivHigh)&&lastPivHigh>prevPivHigh);
   isLH = (!IsNa(lastPivHigh)&&!IsNa(prevPivHigh)&&lastPivHigh<prevPivHigh);
   isHL = (!IsNa(lastPivLow) &&!IsNa(prevPivLow) &&lastPivLow >prevPivLow);
   isLL = (!IsNa(lastPivLow) &&!IsNa(prevPivLow) &&lastPivLow <prevPivLow);

   double swPivH = PivotHigh(g_H, cfg_pivotLen);
   double swPivL = PivotLow (g_L, cfg_pivotLen);

   if(!IsNa(swPivH)){ prevSwingHigh = IsNa(currSwingHigh)?swPivH:currSwingHigh; currSwingHigh=swPivH; }
   if(!IsNa(swPivL)){ prevSwingLow  = IsNa(currSwingLow) ?swPivL:currSwingLow;  currSwingLow =swPivL; }

   bullBOS  = (!IsNa(prevSwingHigh)) && (cl>prevSwingHigh);
   bearBOS  = (!IsNa(prevSwingLow))  && (cl<prevSwingLow);
   bullCHoCH= (!IsNa(prevSwingHigh)) && (cl>prevSwingHigh+atrv*cfg_chochBufferATR);
   bearCHoCH= (!IsNa(prevSwingLow))  && (cl<prevSwingLow -atrv*cfg_chochBufferATR);

   if(cfg_useStrictStruct)
     {
      if(isHH && isHL) structBias=1;
      if(isLH && isLL) structBias=-1;
     }
   else
     {
      if(bullBOS) structBias=1;
      if(bearBOS) structBias=-1;
     }

   structLongOK  = (!cfg_requireStruct) ||
                   (cfg_useStrictStruct && structBias==1 && isHH) ||
                   (!cfg_useStrictStruct && structBias==1);
   structShortOK = (!cfg_requireStruct) ||
                   (cfg_useStrictStruct && structBias==-1 && isLL) ||
                   (!cfg_useStrictStruct && structBias==-1);

   //==================== SECTION 5 (pivot memory) ================
   pivH = swPivH;   // ta.pivothigh(high,pivotLen) - same as swing pivot
   pivL = swPivL;

   double evtPrice=PINE_NA; long evtBar=-1; int evtDir=0;
   if(!IsNa(pivH)){ evtPrice=pivH; evtBar=g_barIndex-cfg_pivotLen; evtDir=1; }
   else if(!IsNa(pivL)){ evtPrice=pivL; evtBar=g_barIndex-cfg_pivotLen; evtDir=-1; }
   if(evtDir!=0)
     {
      prevPivotPrice=lastPivotPrice; prevPivotBar=lastPivotBar; prevPivotDir=lastPivotDir;
      lastPivotPrice=evtPrice; lastPivotBar=evtBar; lastPivotDir=evtDir;
     }

   //==================== SECTION 6 (elite impulse) ===============
   eliteShortImpulse = (!IsNa(pivL)) && prevPivotDir==1  && (!IsNa(prevPivotPrice)) && ((prevPivotPrice-pivL)>atrv*cfg_impulseAtrMult);
   eliteLongImpulse  = (!IsNa(pivH)) && prevPivotDir==-1 && (!IsNa(prevPivotPrice)) && ((pivH-prevPivotPrice)>atrv*cfg_impulseAtrMult);

   //==================== SECTION 8 (accept-bars range) ===========
   g_highestAB = g_H.Highest(cfg_acceptBars);
   g_lowestAB  = g_L.Lowest (cfg_acceptBars);
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/ObservationLiquidity.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  ObservationLiquidity.mqh - SECTION 9 + SECTION 10              |
//|                                                                  |
//|  Section 9  : physics observation scores (expansion/decay/      |
//|               curvature/absorption/liquidity) + physics consensus|
//|  Section 10 : liquidity heatmap (weighted pivot density with     |
//|               age decay) -> liqHeat, liqVacuum, sweep flags,     |
//|               liqSweepOK gate.                                   |
//|                                                                  |
//|  ERF runs BETWEEN these two (see Pipeline), so they are exposed  |
//|  as separate Obs_Compute() / Liq_Compute() calls.                |
//+------------------------------------------------------------------+

//================= SECTION 9 OUTPUTS ==============================
double velocityScore=0, accelerationScore=0, convexityScore=0, expansionScore=0;
double obs_ExpansionScore=0, obs_DecayScore=0, obs_CurvatureScore=0, obs_AbsorptionScore=0, obs_LiquidityScore=0;
double physicsMax=0, physicsDiff=0, physicsConsensus=0;

//================= SECTION 10 OUTPUTS =============================
bool   liqSweepBull=false, liqSweepBear=false, liqVacuum=false, liqSweepOK=false;
double wDensity=0, wDensityAbove=0, wDensityBelow=0;
string liqZone="Open space";

//--- liquidity level store (parallel arrays)
double liqLevels[];
double liqWeights[];
long   liqAges[];
int    liqTypes[];
CSma   g_volSma;

//==================================================================
void ObsLiq_Init()
  {
   ArrayResize(liqLevels,0);
   ArrayResize(liqWeights,0);
   ArrayResize(liqAges,0);
   ArrayResize(liqTypes,0);
   g_volSma.Init(20);
   velocityScore=0; accelerationScore=0; convexityScore=0; expansionScore=0;
   obs_ExpansionScore=0; obs_DecayScore=0; obs_CurvatureScore=0; obs_AbsorptionScore=0; obs_LiquidityScore=0;
   physicsMax=0; physicsDiff=0; physicsConsensus=0;
   liqSweepBull=false; liqSweepBear=false; liqVacuum=false; liqSweepOK=false;
   wDensity=0; wDensityAbove=0; wDensityBelow=0; liqZone="Open space";
  }

//==================================================================
//  SECTION 9 - Physics Observation Layer
//==================================================================
void Obs_Compute()
  {
   double atrv = IsNa(atr)?0.0:atr;
   double effT = cfg_effThresh, dispT = cfg_dispThresh;

   velocityScore     = PineMin(MathAbs(velocity)    /MathMax(atrv*0.1, 1e-10)*50.0, 100.0);
   accelerationScore = PineMin(MathAbs(acceleration)/MathMax(atrv*0.05,1e-10)*50.0, 100.0);
   convexityScore    = PineMin(MathAbs(convSmooth)  /MathMax(atrv*cfg_convMult,1e-10)*25.0, 100.0);
   expansionScore    = PineMin(displacement/MathMax(dispT,1e-10)*50.0, 100.0);

   obs_ExpansionScore = PineMin(
        (efficiency>effT ? efficiency*60.0 : efficiency*30.0) +
        (displacement>dispT ? (displacement/MathMax(dispT,1e-10)-1.0)*20.0 : 0.0) +
        ((velocity>0 && acceleration>0) ? velocityScore*0.2 : ((velocity<0 && acceleration<0) ? velocityScore*0.2 : 0.0)),
        100.0);

   obs_DecayScore = PineMin(
        ((bullMomDecay||bearMomDecay) ? 40.0 : 0.0) +
        (convexityScore>30 ? convexityScore*0.5 : 0.0) +
        (phys_vd70 ? 30.0 : 0.0),
        100.0);

   obs_CurvatureScore = convexityScore;

   obs_AbsorptionScore = PineMin(
        (efficiency<effT*0.7 ? (1.0-efficiency/MathMax(effT,1e-10))*50.0 : 0.0) +
        (phys_vd50 ? 30.0 : 0.0) +
        (displacement<dispT*0.5 ? 20.0 : 0.0),
        100.0);

   obs_LiquidityScore = PineMin(
        obs_DecayScore*0.4 + obs_CurvatureScore*0.4 +
        ((displacement>dispT*1.2 && (bullMomDecay||bearMomDecay)) ? 20.0 : 0.0),
        100.0);

   physicsMax  = MathMax(obs_ExpansionScore, MathMax(obs_DecayScore, MathMax(obs_AbsorptionScore, obs_LiquidityScore)));
   double pmin = MathMin(obs_ExpansionScore, MathMin(obs_DecayScore, MathMin(obs_AbsorptionScore, obs_LiquidityScore)));
   physicsDiff = physicsMax - pmin;
   physicsConsensus = MathMax(0.0, 100.0 - physicsDiff);
  }

//==================================================================
//  SECTION 10 - Liquidity Heatmap
//==================================================================
void Liq_Compute()
  {
   double atrv = IsNa(atr)?0.0:atr;
   double cl   = C_close();

   double swH = g_H.Highest(cfg_liqSweepLookback);
   double swL = g_L.Lowest (cfg_liqSweepLookback);

   liqSweepBull = (!IsNa(flipTop)) && (!IsNa(swH)) && (swH>flipTop);
   liqSweepBear = (!IsNa(flipBot)) && (!IsNa(swL)) && (swL<flipBot);

   //--- volume average + normalised volume of the pivot bar
   double volNow = C_vol(0);
   double volAvg = g_volSma.Update(volNow);
   double volPiv = C_vol(cfg_pivotLen);
   double normVol = (!IsNa(volAvg) && volAvg>0) ? (IsNa(volPiv)?1.0:volPiv)/volAvg : 1.0;

   //--- register a new liquidity level when a pivot confirmed this bar
   if(!IsNa(pivH) || !IsNa(pivL))
     {
      double lvl   = !IsNa(pivH)?pivH:pivL;
      int    lType = !IsNa(pivH)?1:-1;
      double hpv   = C_high(cfg_pivotLen), lpv = C_low(cfg_pivotLen);
      double swRng = ((IsNa(hpv)?0.0:hpv)-(IsNa(lpv)?0.0:lpv))/MathMax(atrv,1e-10);
      double wt    = normVol*swRng;
      int n=ArraySize(liqLevels);
      ArrayResize(liqLevels,n+1);  liqLevels[n]=lvl;
      ArrayResize(liqWeights,n+1); liqWeights[n]=wt;
      ArrayResize(liqAges,n+1);    liqAges[n]=(long)(g_barIndex-cfg_pivotLen);
      ArrayResize(liqTypes,n+1);   liqTypes[n]=lType;
     }
   //--- cap store at 150 (drop oldest)
   while(ArraySize(liqLevels)>150)
     {
      ArrayRemove(liqLevels,0,1);
      ArrayRemove(liqWeights,0,1);
      ArrayRemove(liqAges,0,1);
      ArrayRemove(liqTypes,0,1);
     }

   wDensity=0; wDensityAbove=0; wDensityBelow=0;
   double liqRadiusP    = atrv*cfg_liqRadius;
   double liqRadiusWide = atrv*cfg_liqRadius*3.0;
   int sz=ArraySize(liqLevels);
   for(int i=0;i<sz;i++)
     {
      double lvl=liqLevels[i];
      double wt =liqWeights[i];
      int    age=(int)(g_barIndex - liqAges[i]);
      double dcy=MathPow(cfg_liqAgDecay, age);
      double dist=MathAbs(cl-lvl);
      if(dist<liqRadiusP) wDensity += wt*dcy;
      if(dist<liqRadiusWide)
        {
         if(lvl>cl) wDensityAbove += wt*dcy*(1.0-dist/liqRadiusWide);
         else       wDensityBelow += wt*dcy*(1.0-dist/liqRadiusWide);
        }
     }

   double liqHeatRaw = PineMin((wDensityAbove+wDensityBelow)/2.0, 5.0)/5.0*100.0;
   liqHeat = Clamp(liqHeatRaw, 0.0, 100.0);
   liqZone = (liqHeat<30) ? "Open space" : (liqHeat<70 ? "Active" : "Congested");
   liqVacuum = wDensity<0.5;

   liqSweepOK = (!cfg_requireLiqSweep) ||
                (direction==1  && (liqSweepBull||liqVacuum)) ||
                (direction==-1 && (liqSweepBear||liqVacuum));
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/GeometryWave.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  GeometryWave.mqh - SECTION 11 (Geometry) + SECTION 12 (Wave     |
//|  Intelligence System).                                           |
//|                                                                  |
//|  Section 11 : order-block freshness, origin/extreme/flipzone     |
//|               geometry, available space, zone precision.         |
//|  Section 12 : ideal-state similarity model, geometric position,  |
//|               convexity maturity, wave progress, model fit, the  |
//|               belief engine (expansion/convexity/creation/       |
//|               absorption/retracement/demand-return), phase       |
//|               proximity, hypothesis, prediction, validation,     |
//|               adaptive confidence and wave-deviation engines.    |
//|                                                                  |
//|  Runs after Liq_Compute and before WaveSpawn_Compute, so the     |
//|  wave-context vars it reads carry the previous bar's value -     |
//|  exactly the forward-declared-var lag of the source.             |
//+------------------------------------------------------------------+

//================= SECTION 11 OUTPUTS =============================
long   obAge_g=0;
bool   obFresh=true;
double obFreshness=0.0;
double originToExtreme=PINE_NA, extremeToFlipzone=PINE_NA, flipzoneWidth=PINE_NA;
double remainingRoom=PINE_NA, availableSpace=PINE_NA, zonePrecision=0.0;
bool   geoFullConvexityPossible=false, geoPartialConvexityPossible=false, geoAbsorptionOnly=false;

//================= SECTION 12 OUTPUTS =============================
double sim_Expansion=0,sim_PreConv=0,sim_Induction=0,sim_Liquidity=0,sim_Creation=0,sim_Absorption=0,sim_Retracement=0,sim_DemandReturn=0;
double posDistToCreation=0,posDistToAbsorption=0,posDistToRetracement=0,posDistToDemand=0,posDistToOrigin=0;
double waveProgress=30.0, waveModelFit=50.0;
double expansionBelief=0,convexityBelief=0,creationBelief=0,absorptionBelief=0,retracementBelief=0,demandReturnBelief=0;
double d_expansionBelief=0,d_convexityBelief=0,d_creationBelief=0,d_absorptionBelief=0,d_retracementBelief=0,d_demandReturnBelief=0;
double modelConfidence=50.0;
bool   liquidityEvidence=false;
double waveDeviation=0.0; bool deviationAlert=false;
string primaryHypothesis="EXPANSION"; double primaryHypothesisConf=0.0;
double expansionProximity=0,convexityProximity=0,creationProximity=0,absorptionProximity=0,retracementProximity=0,demandReturnProximity=0;
string expectedNextPhase="Expansion"; double expectedNextProb=50.0; double predReliability=50.0;

//--- velocity[2] history (chart bars)
CRing  g_velHist;
//--- validation engine state
int    predOutcomes[100];
int    predTotalIdx=0;
string lastExpectedPhase="Point 4 Origin";
string lastIE1APhase="Point 4 Origin";

//==================================================================
double f_idealSim(const double e,const double d,const double v,const double c,
                  const double eI,const double dI,const double vI,const double cI)
  {
   double diff = (e-eI)*(e-eI)+(d-dI)*(d-dI)+(v-vI)*(v-vI)+(c-cI)*(c-cI);
   return MathMax(0.0, 100.0*(1.0-diff/4.0));
  }

double f_predAcc(const int n)
  {
   int cnt   = (int)MathMin(n, predTotalIdx);
   int start = (int)MathMax(0, predTotalIdx-cnt);
   int sum=0;
   if(cnt>0) for(int i=start;i<predTotalIdx;i++) sum += predOutcomes[i%100];
   return cnt>0 ? (double)sum/cnt*100.0 : 50.0;
  }

//==================================================================
void GeoWave_Init()
  {
   g_velHist.Init(8);
   ArrayInitialize(predOutcomes,0);
   predTotalIdx=0;
   lastExpectedPhase="Point 4 Origin";
   lastIE1APhase="Point 4 Origin";
   waveProgress=30.0; waveModelFit=50.0;
   expansionBelief=0;convexityBelief=0;creationBelief=0;absorptionBelief=0;retracementBelief=0;demandReturnBelief=0;
   modelConfidence=50.0;
   convexityMaturity=0.0;
  }

//==================================================================
void GeoWave_Compute()
  {
   double cl=C_close(), hi=C_high(), lo=C_low();
   double atrv=IsNa(atr)?0.0:atr;
   double effT=cfg_effThresh, dispT=cfg_dispThresh;
   double bSmAlpha=2.0/(cfg_beliefSmooth+1.0);

   //==================== SECTION 11 - GEOMETRY ===================
   obAge_g = (obBirthBar>=0) ? (g_barIndex-obBirthBar) : 0;
   obFresh = (obAge_g <= cfg_obMaxBars);
   obFreshness = (obBirthBar>=0) ? MathMax(0.0, 1.0-(double)obAge_g/(double)cfg_obMaxBars) : 0.0;

   originToExtreme=PINE_NA;
   if(!IsNa(point4OriginHigh) && !IsNa(point4OriginLow))
     {
      double orig = (direction==1)?point4OriginLow:point4OriginHigh;
      double extr = (direction==1)?Nz(cycleHigh,orig):Nz(cycleLow,orig);
      originToExtreme = MathAbs(extr-orig);
     }
   extremeToFlipzone=PINE_NA;
   if(!IsNa(flipTop)&&!IsNa(flipBot)&&!IsNa(cycleHigh)&&!IsNa(cycleLow))
     {
      double fzMid=(flipTop+flipBot)/2.0;
      double extr=(direction==1)?cycleHigh:cycleLow;
      extremeToFlipzone=MathAbs(extr-fzMid);
     }
   flipzoneWidth = (!IsNa(flipTop)&&!IsNa(flipBot)) ? (flipTop-flipBot) : PINE_NA;
   remainingRoom=PINE_NA;
   if(!IsNa(flipTop)&&!IsNa(flipBot))
     {
      double fzMid=(flipTop+flipBot)/2.0;
      remainingRoom=PineMin(MathAbs(cl-fzMid)/MathMax(atrv*4.0,1e-10)*100.0,100.0);
     }
   availableSpace=remainingRoom;
   zonePrecision = (!IsNa(flipzoneWidth)) ? MathMax(100.0-PineMin((flipzoneWidth/MathMax(atrv*0.5,1e-10))*50.0,100.0),0.0) : 0.0;
   geoFullConvexityPossible = (!IsNa(originToExtreme)&&!IsNa(flipzoneWidth)&&originToExtreme>atrv*6.0&&flipzoneWidth<atrv*3.0);
   geoPartialConvexityPossible = (!IsNa(originToExtreme)&&originToExtreme>atrv*3.0&&originToExtreme<=atrv*6.0);
   geoAbsorptionOnly = (!IsNa(originToExtreme)&&originToExtreme<=atrv*3.0);

   //==================== SECTION 12 - REF NORMS ==================
   double rEff =PineMin(efficiency,1.0);
   double rDisp=PineMin(displacement/MathMax(dispT*2.0,1e-10),1.0);
   double rVel =PineMin(MathAbs(velocity)/MathMax(atrv*0.15,1e-10),1.0);
   double rCurv=PineMin(MathAbs(convSmooth)/MathMax(atrv*cfg_convMult*2.0,1e-10),1.0);

   sim_Expansion    = f_idealSim(rEff,rDisp,rVel,rCurv, 0.85,0.80,0.80,0.10);
   sim_PreConv      = f_idealSim(rEff,rDisp,rVel,rCurv, 0.60,0.55,0.40,0.50);
   sim_Induction    = f_idealSim(rEff,rDisp,rVel,rCurv, 0.65,0.60,0.30,0.60);
   sim_Liquidity    = f_idealSim(rEff,rDisp,rVel,rCurv, 0.45,0.85,0.15,0.80);
   sim_Creation     = f_idealSim(rEff,rDisp,rVel,rCurv, 0.30,0.70,0.05,0.90);
   sim_Absorption   = f_idealSim(rEff,rDisp,rVel,rCurv, 0.20,0.25,0.10,0.40);
   sim_Retracement  = f_idealSim(rEff,rDisp,rVel,rCurv, 0.70,0.65,0.65,0.25);
   sim_DemandReturn = f_idealSim(rEff,rDisp,rVel,rCurv, 0.50,0.40,0.35,0.20);

   //==================== 12-POS GEOMETRIC POSITION ===============
   double waveTotalRange   = (!IsNa(originToExtreme)) ? originToExtreme : atrv*5.0;
   double currentToFlipMid = (!IsNa(flipTop)&&!IsNa(flipBot)) ? MathAbs(cl-(flipTop+flipBot)/2.0) : atrv*4.0;
   double currentToExtreme = (direction==1) ? MathAbs(Nz(cycleHigh,cl+atrv)-cl) : MathAbs(cl-Nz(cycleLow,cl-atrv));
   double distToOrigin_atr = (!IsNa(point4OriginHigh)&&!IsNa(point4OriginLow)) ?
        MathAbs(cl-(direction==1?point4OriginLow:point4OriginHigh))/MathMax(atrv,1e-10) :
        waveTotalRange/MathMax(atrv,1e-10);
   double posNormDen=MathMax(waveTotalRange,atrv*0.5);
   posDistToCreation    = PineMin(currentToExtreme/posNormDen*100.0,100.0);
   posDistToAbsorption  = PineMin((currentToExtreme+atrv*0.5)/posNormDen*100.0,100.0);
   posDistToRetracement = PineMin((currentToExtreme+atrv*1.5)/posNormDen*100.0,100.0);
   posDistToDemand      = PineMin(currentToFlipMid/posNormDen*100.0,100.0);
   posDistToOrigin      = PineMin(distToOrigin_atr*atrv/posNormDen*100.0,100.0);

   //==================== 12-CM CONVEXITY MATURITY ================
   //  uses PREVIOUS-bar inductionEvidence/preConvEvidence (forward vars)
   g_velHist.Push(velocity);
   double vel2 = g_velHist.Has(2) ? g_velHist.Get(2) : velocity;
   double expWeaknessScore = PineMin(
        ((efficiency<effT ? (1.0-efficiency/MathMax(effT,1e-10))*40.0 : 0.0) +
         (obs_DecayScore*0.30) +
         (MathAbs(velocity)<MathAbs(vel2)*0.6 ? 20.0 : 0.0)) * (100.0/90.0), 100.0);
   double inductionMatScore = PineMin(
        (inductionEvidence?35.0:0.0) + (obs_CurvatureScore*0.35) + (preConvEvidence?20.0:0.0) +
        ((displacement>dispT*1.2 && (bullMomDecay||bearMomDecay))?10.0:0.0), 100.0);
   double liqMatScore = PineMin(
        (obs_LiquidityScore*0.50) + ((liqSweepBull||liqSweepBear)?30.0:0.0) +
        (liqHeat>60?20.0:(liqHeat>30?10.0:0.0)), 100.0);
   double rawConvexityMaturity = PineMin(expWeaknessScore*0.35 + inductionMatScore*0.35 + liqMatScore*0.30, 100.0);
   convexityMaturity = convexityMaturity + bSmAlpha*(rawConvexityMaturity-convexityMaturity);

   //==================== 12-WP WAVE PROGRESS =====================
   double progressFromGeom=PINE_NA;
   if(!IsNa(point4OriginHigh)&&!IsNa(flipTop)&&!IsNa(flipBot))
     {
      double origin=(direction==1)?point4OriginLow:point4OriginHigh;
      double extreme=(direction==1)?Nz(cycleHigh,cl+atrv):Nz(cycleLow,cl-atrv);
      double fzMid=(flipTop+flipBot)/2.0;
      double totalMove=MathAbs(extreme-origin);
      double toFzMid=MathAbs(extreme-fzMid);
      double traveled=MathAbs(cl-origin);
      double expProg=totalMove>1e-10?PineMin(traveled/totalMove*60.0,60.0):30.0;
      double retrMove=MathAbs(cl-extreme);
      double retrProg=toFzMid>1e-10?PineMin(retrMove/MathMax(toFzMid,1e-10)*40.0,40.0):0.0;
      double retrWeight=PineMin(obs_AbsorptionScore/40.0,1.0);
      progressFromGeom=expProg+retrProg*retrWeight;
     }
   double geomProgress=Nz(progressFromGeom,30.0);

   double simAnchor =
        (sim_DemandReturn>=sim_Retracement&&sim_DemandReturn>=sim_Absorption&&sim_DemandReturn>=sim_Creation&&sim_DemandReturn>=sim_Expansion)?95.0:
        (sim_Retracement>=sim_Absorption&&sim_Retracement>=sim_Creation&&sim_Retracement>=sim_Expansion)?87.0:
        (sim_Absorption>=sim_Creation&&sim_Absorption>=sim_Expansion)?75.0:
        (sim_Creation>=sim_Liquidity&&sim_Creation>=sim_Expansion)?62.0:
        (sim_Liquidity>=sim_Induction&&sim_Liquidity>=sim_Expansion)?52.0:
        (sim_Induction>=sim_PreConv&&sim_Induction>=sim_Expansion)?43.0:
        (sim_PreConv>=sim_Expansion)?33.0:22.0;
   double convWeight=MathMax(0.0,1.0-MathAbs(simAnchor-47.5)/14.5);
   double convAdjust=(convexityMaturity/100.0)*(simAnchor-33.0)*0.50*convWeight;
   double physProgress=simAnchor+convAdjust;
   double rawWaveProgress=geomProgress*0.60+physProgress*0.40;
   waveProgress = waveProgress + bSmAlpha*(rawWaveProgress-waveProgress);
   waveProgress = Clamp(waveProgress,0.0,100.0);

   //==================== 12-FIT MODEL FIT ========================
   double bestSim=MathMax(sim_Expansion,MathMax(sim_PreConv,MathMax(sim_Induction,MathMax(sim_Liquidity,
                   MathMax(sim_Creation,MathMax(sim_Absorption,MathMax(sim_Retracement,sim_DemandReturn)))))));
   double geomConsistency=PineMin(
        ((!IsNa(originToExtreme)&&originToExtreme>atrv*2.0)?30.0:0.0)+
        ((!IsNa(flipzoneWidth)&&flipzoneWidth<atrv*4.0)?25.0:0.0)+
        ((!IsNa(cycleHigh)||!IsNa(cycleLow))?20.0:0.0)+
        (direction!=0?25.0:0.0),100.0);
   double rawWaveModelFit=bestSim*0.55+geomConsistency*0.45;
   waveModelFit = waveModelFit + bSmAlpha*(rawWaveModelFit-waveModelFit);
   waveModelFit = Clamp(waveModelFit,0.0,100.0);

   //==================== 12A BELIEF ENGINE =======================
   preConvEvidence   = (bullMomDecay||bearMomDecay);
   inductionEvidence = (direction==1&&bearImpulse&&structBias==1)||(direction==-1&&bullImpulse&&structBias==-1);
   liquidityEvidence = (obs_LiquidityScore>50.0 && obs_DecayScore>40.0);

   double expPosMult=waveProgress<40.0?1.20:(waveProgress<60.0?0.80:0.50);
   double rawExp=PineMin((obs_ExpansionScore*0.45+((bullImpulse||bearImpulse)?30.0:0.0)+(efficiency>effT*1.1?15.0:0.0)+sim_Expansion*0.10)*expPosMult,100.0);

   double convPosMult=(waveProgress>=30.0&&waveProgress<=65.0)?1.30:0.70;
   double rawConv=PineMin((obs_DecayScore*0.30+obs_CurvatureScore*0.25+(preConvEvidence?15.0:0.0)+(inductionEvidence?10.0:0.0)+(liquidityEvidence?5.0:0.0)+convexityMaturity*0.08)*convPosMult,100.0);

   double creatPosMult=(waveProgress>=45.0&&waveProgress<=68.0)?1.40:0.60;
   double creatNewExtreme=((!IsNa(cycleHigh)&&!IsNa(cycleLow))&&((direction==1&&hi>=Nz(cycleHigh,hi)*0.998)||(direction==-1&&lo<=Nz(cycleLow,lo)*1.002)))?20.0:0.0;
   double rawCreat=PineMin(((convexityMaturity>50?convexityMaturity*0.12:0.0)+(obs_DecayScore>60?obs_DecayScore*0.20:0.0)+(obs_LiquidityScore>50?obs_LiquidityScore*0.20:0.0)+(obs_AbsorptionScore>20?obs_AbsorptionScore*0.15:0.0)+creatNewExtreme+sim_Creation*0.10+(posDistToCreation<15.0?(15.0-posDistToCreation)*1.0:0.0))*creatPosMult,100.0);

   double rawAbs=PineMin(obs_AbsorptionScore*0.50+(efficiency<effT*0.6?25.0:0.0)+(displacement<dispT*0.5?15.0:0.0)+sim_Absorption*0.10,100.0);

   double rawRetr=PineMin((((direction==1&&bearImpulse)||(direction==-1&&bullImpulse))?45.0:0.0)+(rawAbs>50?rawAbs*0.30:0.0)+(obs_CurvatureScore>40?15.0:0.0)+sim_Retracement*0.10,100.0);

   double rawDR=PineMin(((!IsNa(flipTop)&&!IsNa(flipBot)&&cl<=flipTop&&cl>=flipBot)?35.0:0.0)+(rawRetr>60?rawRetr*0.30:0.0)+(liqHeat>50?liqHeat*0.15:0.0)+((liqSweepBull||liqSweepBear)?20.0:0.0)+sim_DemandReturn*0.10,100.0);

   expansionBelief    = expansionBelief    + bSmAlpha*(Nz(rawExp,0.0)  -expansionBelief);
   convexityBelief    = convexityBelief    + bSmAlpha*(Nz(rawConv,0.0) -convexityBelief);
   creationBelief     = creationBelief     + bSmAlpha*(Nz(rawCreat,0.0)-creationBelief);
   absorptionBelief   = absorptionBelief   + bSmAlpha*(Nz(rawAbs,0.0)  -absorptionBelief);
   retracementBelief  = retracementBelief  + bSmAlpha*(Nz(rawRetr,0.0) -retracementBelief);
   demandReturnBelief = demandReturnBelief + bSmAlpha*(Nz(rawDR,0.0)   -demandReturnBelief);

   d_expansionBelief    = Clamp(expansionBelief,0.0,100.0);
   d_convexityBelief    = Clamp(convexityBelief,0.0,100.0);
   d_creationBelief     = Clamp(creationBelief,0.0,100.0);
   d_absorptionBelief   = Clamp(absorptionBelief,0.0,100.0);
   d_retracementBelief  = Clamp(retracementBelief,0.0,100.0);
   d_demandReturnBelief = Clamp(demandReturnBelief,0.0,100.0);

   //==================== 12B PHASE PROXIMITY =====================
   expansionProximity = PineMin(sim_Expansion*0.50+((bullImpulse||bearImpulse)?25.0:0.0)+(waveProgress<35.0?(35.0-waveProgress)*0.50:0.0)+(obs_ExpansionScore*0.25),100.0);
   convexityProximity = PineMin(sim_PreConv*0.25+sim_Induction*0.25+sim_Liquidity*0.20+(preConvEvidence?15.0:0.0)+((waveProgress>=30.0&&waveProgress<=65.0)?15.0:0.0),100.0);
   creationProximity  = PineMin(sim_Creation*0.50+((!IsNa(cycleHigh)&&direction==1&&hi>=Nz(cycleHigh,hi)*0.995)?25.0:0.0)+((!IsNa(cycleLow)&&direction==-1&&lo<=Nz(cycleLow,lo)*1.005)?25.0:0.0)+(convexityMaturity>60?convexityMaturity*0.25:0.0),100.0);
   absorptionProximity= PineMin(sim_Absorption*0.50+(obs_AbsorptionScore*0.35)+((waveProgress>=68.0&&waveProgress<=80.0)?15.0:0.0),100.0);
   retracementProximity=PineMin(sim_Retracement*0.50+(((direction==1&&bearImpulse)||(direction==-1&&bullImpulse))?30.0:0.0)+((waveProgress>=78.0&&waveProgress<=93.0)?20.0:0.0),100.0);
   demandReturnProximity=PineMin(sim_DemandReturn*0.50+((!IsNa(flipTop)&&!IsNa(flipBot)&&cl<=flipTop&&cl>=flipBot)?30.0:0.0)+(waveProgress>=90.0?20.0:0.0),100.0);

   //==================== 12E PREDICTION ENGINE ===================
   double predExp =(waveProgress<35.0?(35.0-waveProgress)*1.00:0.0)+(expansionBelief>55?expansionBelief*0.30:0.0)+(convexityMaturity<25?20.0:0.0)+(posDistToCreation>30?15.0:0.0)+((htfAlign==direction&&direction!=0)?15.0:0.0);
   double predConv=((waveProgress>=25.0&&waveProgress<=60.0)?30.0:0.0)+(convexityMaturity>20?convexityMaturity*0.30:0.0)+(obs_DecayScore>40?20.0:0.0)+(m1ConvexityEmer?15.0:0.0)+(preConvEvidence?15.0:0.0);
   double predCreat=(convexityMaturity>55?(convexityMaturity-55.0)*1.20:0.0)+(posDistToCreation<20.0?(20.0-posDistToCreation)*2.00:0.0)+(obs_LiquidityScore>55?20.0:0.0)+((liqSweepBull||liqSweepBear)?15.0:0.0)+(m1LiquidityEmer?10.0:0.0);
   double predAbs=(predCreat>50?predCreat*0.40:0.0)+(obs_AbsorptionScore>35?obs_AbsorptionScore*0.30:0.0)+(m1AbsorptionEmer?20.0:0.0)+((waveProgress>=60.0&&waveProgress<=78.0)?15.0:0.0);
   double predRetr=(absorptionBelief>45?absorptionBelief*0.35:0.0)+(((direction==1&&bearMicroImpulse)||(direction==-1&&bullMicroImpulse))?25.0:0.0)+((waveProgress>=72.0&&waveProgress<=90.0)?20.0:0.0)+(physicsConsensus<40?10.0:0.0);
   double predDR=(retracementBelief>45?retracementBelief*0.35:0.0)+(posDistToDemand<20.0?(20.0-posDistToDemand)*1.50:0.0)+((liqSweepBull||liqSweepBear)?20.0:0.0)+(waveProgress>=88.0?(waveProgress-88.0)*1.20:0.0);
   double maxPred=MathMax(predExp,MathMax(predConv,MathMax(predCreat,MathMax(predAbs,MathMax(predRetr,predDR)))));

   expectedNextPhase =
        (predDR>=predRetr&&predDR>=predAbs&&predDR>=predCreat&&predDR>=predConv&&predDR>=predExp)?(direction==-1?"Supply Return":"Demand Return"):
        (predRetr>=predAbs&&predRetr>=predCreat&&predRetr>=predConv&&predRetr>=predExp)?"Retracement":
        (predAbs>=predCreat&&predAbs>=predConv&&predAbs>=predExp)?"Transition":
        (predCreat>=predConv&&predCreat>=predExp)?(direction==-1?"New Low":"New High"):
        (predConv>=predExp)?"Expansion Pre-Convexity":"Expansion";
   expectedNextProb = maxPred>0 ? PineMin(maxPred/MathMax(maxPred+30.0,1.0)*100.0,95.0) : 50.0;

   //==================== 12F VALIDATION ENGINE ===================
   bool predTransition = (ie1a_currentPhase!=lastIE1APhase);
   bool predSucceeded  = predTransition && (ie1a_currentPhase==lastExpectedPhase);
   if(predTransition)
     {
      predOutcomes[predTotalIdx%100] = predSucceeded?1:0;
      predTotalIdx++;
     }
   lastExpectedPhase = expectedNextPhase;
   lastIE1APhase     = ie1a_currentPhase;
   double predAcc10=f_predAcc(10), predAcc25=f_predAcc(25), predAcc50=f_predAcc(50), predAcc100=f_predAcc(100);
   predReliability = predAcc10*0.4+predAcc25*0.3+predAcc50*0.2+predAcc100*0.1;

   //==================== 12G ADAPTIVE CONFIDENCE =================
   double confInc=(predSucceeded?3.0:0.0)+(physicsConsensus>70?2.0:0.0)+((htfAlign==direction&&direction!=0)?1.5:0.0)+((dir_tf1==dir_tf2&&dir_tf1!=0)?1.0:0.0);
   double confDec=((predTransition&&!predSucceeded)?2.0:0.0)+(physicsDiff>60?2.0:0.0)+((htfAlign!=direction&&direction!=0)?1.5:0.0)+((dir_tf1!=dir_tf2&&dir_tf1!=0&&dir_tf2!=0)?1.0:0.0);
   modelConfidence = Clamp(modelConfidence+confInc-confDec-cfg_confDecayRate*(modelConfidence-50.0),10.0,100.0);

   //==================== 12H WAVE DEVIATION ======================
   double idealExpSig=efficiency;
   double idealConvSig=obs_DecayScore/100.0;
   double idealAbsSig=obs_AbsorptionScore/100.0;
   double waveDevRaw=MathAbs(idealExpSig-(ie1a_hypFamily=="EXPANSION"?0.85:0.30))*40.0+
                     MathAbs(idealConvSig-(ie1a_hypFamily=="CONVEXITY FORMING"?0.70:0.20))*30.0+
                     MathAbs(idealAbsSig-(ie1a_hypFamily=="ABSORPTION"?0.70:0.15))*30.0;
   waveDeviation=PineMin(waveDevRaw*100.0,100.0);
   deviationAlert=waveDeviation>cfg_devReinterp;

   //==================== HYPOTHESIS (display relay) ==============
   primaryHypothesis = ie1a_hypFamily;
   double hypExpN = Clamp(expansionBelief,0,100);
   double hypConvN= Clamp(convexityBelief,0,100);
   double hypCreatN=Clamp(creationBelief,0,100);
   double hypAbsN = Clamp(absorptionBelief,0,100);
   double hypRetrN= Clamp(retracementBelief,0,100);
   double hypDRN  = Clamp(demandReturnBelief,0,100);
   primaryHypothesisConf =
        primaryHypothesis=="EXPANSION"?hypExpN:
        primaryHypothesis=="CONVEXITY FORMING"?hypConvN:
        primaryHypothesis=="CREATION FORMING"?hypCreatN:
        primaryHypothesis=="ABSORPTION"?hypAbsN:
        primaryHypothesis=="RETRACEMENT"?hypRetrN:hypDRN;
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/WaveSpawn.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  WaveSpawn.mqh - SECTION 13 (Wave Spawn) + SECTION 14            |
//|                  (Induction Zone Classification).                |
//|                                                                  |
//|  Section 13 : the active wave is governed by the fixed M5 (L0)   |
//|               structure engine. When l0_dir flips, a new wave    |
//|               spawns: flip-zone, Point-4 origin, inducement      |
//|               zones, cycle extremes reset. Recursive entry       |
//|               cycles re-arm on a true CHoCH / structure flip in  |
//|               the Demand/Supply Return phase. Hard invalidation  |
//|               or a soft rotation reset clears the wave.          |
//|  Section 14 : inducement-zone classification -> inducConfidence  |
//|               and flipzoneStagesComplete / flipzoneScore.        |
//+------------------------------------------------------------------+

//================= SECTION 13/14 OUTPUTS ==========================
bool   expInducBuyEv=false, expInducSellEv=false, retrInducBuyEv=false, retrInducSellEv=false;
bool   priceInDemand=false, priceInSupply=false;
bool   trueCHoCH_bull=false, trueCHoCH_bear=false, structFlipBull=false, structFlipBear=false;
bool   recursiveTrigger=false;
bool   bullInvalid=false, bearInvalid=false, opposingMove=false, hardInvalid=false, softReset=false, safeToReset=false;
long   barsSinceCont=0;

bool   inRetracementInducZone=false, inShortRetrInducZone=false, inExpansionInducZone=false, inShortExpInducZone=false;
double inducConfidence=0.0;
bool   expansionPreConvSeen=false, expansionInductionConf=false, retracementPreConvSeen=false, retracementInductionConf=false;
bool   expConvFormationActive=false, retrConvFormationActive=false, convexityComplete=false;
int    flipzoneStagesComplete=0;
double flipzoneScore=0.0;

//==================================================================
void WaveSpawn_Init() {}

bool IsReturnPhase()
  {
   return(ie1a_currentPhase=="Demand Return" || ie1a_currentPhase=="Supply Return");
  }

//--- common spawn routine (mirrors f_spawnWave + assignment block)
void DoSpawn(const int newDir,const bool useL0Override)
  {
   double atrv=IsNa(atr)?0.0:atr;
   double zw  = atrv*cfg_inducZoneWidth;
   double obTop=(newDir==1)?lastPivotPrice:prevPivotPrice;
   double obBot=(newDir==1)?prevPivotPrice:lastPivotPrice;
   long   anchBar=prevPivotBar;
   if(useL0Override){ obTop=Nz(l0_p4High,obTop); obBot=Nz(l0_p4Low,obBot); }
   double fzIP=FindInducPrice(anchBar,obTop,obBot,cfg_inducLookback);
   double fzL =(!IsNa(fzIP))?fzIP-zw:PINE_NA;
   double fzH =(!IsNa(fzIP))?fzIP+zw:PINE_NA;

   direction=newDir;
   flipTop=obTop; flipBot=obBot;
   barsInZone=0;
   obBirthBar=g_barIndex;
   point4OriginHigh=obTop; point4OriginLow=obBot; point4OriginBar=g_barIndex;
   flipzoneInducPrice=fzIP; flipzoneInducLow=fzL; flipzoneInducHigh=fzH;
   inducExpOriginHigh=PINE_NA; inducExpExtremeLow=PINE_NA; inducExpOriginLow=PINE_NA; inducExpExtremeHigh=PINE_NA;
   inducRetrOriginHigh=PINE_NA; inducRetrExtremeLow=PINE_NA; inducRetrOriginLow=PINE_NA; inducRetrExtremeHigh=PINE_NA;
   inducZoneLow=PINE_NA; inducZoneHigh=PINE_NA;
   cycleHigh=C_high(); cycleLow=C_low();
   lastSpawnDir=newDir;
  }

//==================================================================
void WaveSpawn_Compute()
  {
   double cl=C_close(), hi=C_high(), lo=C_low();
   double atrv=IsNa(atr)?0.0:atr;
   double zw  = atrv*cfg_inducZoneWidth;

   //==================== SECTION 13 - SPAWN ======================
   bool allowSpawn = (l0_dir!=0 && l0_dir!=direction);
   if(allowSpawn)
     {
      DoSpawn(l0_dir, true);
      contBar=-1;
      isRecursiveWave=false; entryCycle=0; waveDepth=0;
     }

   //--- track cycle extremes
   if(direction==1  && hi>Nz(cycleHigh,hi)) cycleHigh=hi;
   if(direction==-1 && lo<Nz(cycleLow,lo))  cycleLow=lo;

   //--- expansion inducement events
   expInducBuyEv  = (direction==1  && bearImpulse && structBias==1);
   expInducSellEv = (direction==-1 && bullImpulse && structBias==-1);

   if(expInducBuyEv && IsNa(inducExpOriginHigh))
     {
      inducExpOriginHigh = Nz(point4OriginHigh, Nz(cycleHigh,hi));
      inducExpExtremeLow = lo;
      double basis = Nz(point4OriginHigh, lo);
      inducZoneLow  = basis-zw;
      inducZoneHigh = basis+zw;
     }
   if(expInducSellEv && IsNa(inducExpOriginLow))
     {
      inducExpOriginLow   = Nz(point4OriginLow, Nz(cycleLow,lo));
      inducExpExtremeHigh = hi;
      double basis = Nz(point4OriginLow, hi);
      inducZoneLow  = basis-zw;
      inducZoneHigh = basis+zw;
     }
   if(!IsNa(inducExpExtremeLow) && direction==1 && lo<inducExpExtremeLow)
     { inducExpExtremeLow=lo; inducZoneLow=lo-zw; inducZoneHigh=lo+zw; }
   if(!IsNa(inducExpExtremeHigh) && direction==-1 && hi>inducExpExtremeHigh)
     { inducExpExtremeHigh=hi; inducZoneLow=hi-zw; inducZoneHigh=hi+zw; }

   nearFlipzone = (!IsNa(flipTop)&&!IsNa(flipBot)&&cl<=flipTop*1.02&&cl>=flipBot*0.98);

   retrInducBuyEv  = (direction==1  && bullImpulse && structBias==-1 && nearFlipzone);
   retrInducSellEv = (direction==-1 && bearImpulse && structBias==1  && nearFlipzone);

   if(retrInducBuyEv && IsNa(inducRetrOriginLow))
     { inducRetrOriginLow=Nz(cycleLow,lo); inducRetrExtremeHigh=hi; inducZoneLow=hi-zw; inducZoneHigh=hi+zw; }
   if(retrInducSellEv && IsNa(inducRetrOriginHigh))
     { inducRetrOriginHigh=Nz(cycleHigh,hi); inducRetrExtremeLow=lo; inducZoneLow=lo-zw; inducZoneHigh=lo+zw; }
   if(!IsNa(inducRetrExtremeHigh) && direction==1 && hi>inducRetrExtremeHigh)
     { inducRetrExtremeHigh=hi; inducZoneLow=hi-zw; inducZoneHigh=hi+zw; }
   if(!IsNa(inducRetrExtremeLow) && direction==-1 && lo<inducRetrExtremeLow)
     { inducRetrExtremeLow=lo; inducZoneLow=lo-zw; inducZoneHigh=lo+zw; }

   closeInside  = (!IsNa(flipTop)&&cl<=flipTop&&cl>=flipBot);
   priceInDemand= (!IsNa(flipBot)&&lo<flipBot&&(!IsNa(point4OriginHigh)&&lo<=point4OriginHigh));
   priceInSupply= (!IsNa(flipTop)&&hi>flipTop&&(!IsNa(point4OriginLow)&&hi>=point4OriginLow));

   trueCHoCH_bull = (direction==1  && priceInDemand && bullImpulse && liqSweepOK);
   trueCHoCH_bear = (direction==-1 && priceInSupply && bearImpulse && liqSweepOK);
   structFlipBull = (direction==1  && bullConvShift && structBias==-1);
   structFlipBear = (direction==-1 && bearConvShift && structBias==1);

   recursiveTrigger = (trueCHoCH_bull||trueCHoCH_bear||structFlipBull||structFlipBear) &&
                      IsReturnPhase() && demandReturnBelief>40 && direction!=0 && !IsNa(flipTop);

   if(recursiveTrigger && (recursiveFiredBar<0 || (g_barIndex-recursiveFiredBar)>cfg_resetBars))
     {
      recursiveJustFired=true; recursiveFiredBar=g_barIndex; recursiveComplete=true;
     }
   else recursiveJustFired=false;

   if(recursiveJustFired)
     {
      waveGeneration++;
      entryCycle=(int)MathMin(entryCycle+1,4);
      isRecursiveWave=true;
      waveDepth=entryCycle;
      int nextDir = (l0_dir!=0) ? l0_dir : ((bullImpulse||bullConvShift)?1:-1);
      DoSpawn(nextDir, false);
      direction = (l0_dir!=0) ? l0_dir : nextDir;
      contBar=g_barIndex;
     }

   //--- retest accumulation in return phase
   if(IsReturnPhase())
     {
      barsInZone = closeInside ? barsInZone+1 : 0;
      if(barsInZone>=cfg_acceptBars){ retestHigh=g_highestAB; retestLow=g_lowestAB; }
     }

   //--- invalidation / reset
   barsSinceCont = (contBar>=0) ? (g_barIndex-contBar) : ((obBirthBar>=0)?(g_barIndex-obBirthBar):0);
   bullInvalid = (direction==1  && (!IsNa(flipBot)) && cl<flipBot-atrv*0.5);
   bearInvalid = (direction==-1 && (!IsNa(flipTop)) && cl>flipTop+atrv*0.5);
   opposingMove= ((direction==1&&bearImpulse)||(direction==-1&&bullImpulse));
   hardInvalid = bullInvalid||bearInvalid;
   softReset   = (barsSinceCont>cfg_resetBars && opposingMove && !IsReturnPhase() &&
                  demandReturnBelief<30 && expansionBelief<30 && !erf_suppressRotation);
   safeToReset = hardInvalid||softReset;

   if(direction!=l0_dir && safeToReset)
     {
      direction=0; lastSpawnDir=0; flipTop=PINE_NA; flipBot=PINE_NA; contBar=-1; obBirthBar=-1;
      barsInZone=0; isRecursiveWave=false; entryCycle=0; waveDepth=0; recursiveComplete=false;
     }

   //==================== SECTION 14 - INDUCTION CLASS ============
   inRetracementInducZone = (!IsNa(pivL)&&!IsNa(inducZoneLow)&&!IsNa(inducZoneHigh)&&
        direction==1 && pivL>=inducZoneLow && pivL<=inducZoneHigh && retrInducBuyEv);
   inShortRetrInducZone = (!IsNa(pivH)&&!IsNa(inducZoneLow)&&!IsNa(inducZoneHigh)&&
        direction==-1 && pivH>=inducZoneLow && pivH<=inducZoneHigh && retrInducSellEv);
   inExpansionInducZone = (!IsNa(pivH)&&!IsNa(inducZoneLow)&&!IsNa(inducZoneHigh)&&
        direction==1 && pivH>=inducZoneLow && pivH<=inducZoneHigh && expInducBuyEv);
   inShortExpInducZone = (!IsNa(pivL)&&!IsNa(inducZoneLow)&&!IsNa(inducZoneHigh)&&
        direction==-1 && pivL>=inducZoneLow && pivL<=inducZoneHigh && expInducSellEv);

   inducConfidence=0.0;
   if(direction==1 && inRetracementInducZone) inducConfidence=1.0;
   else if(direction==1 && !IsNa(pivL) && !IsNa(flipTop) && !IsNa(flipBot) &&
           pivL<flipTop && pivL>flipBot && !inRetracementInducZone) inducConfidence=-0.5;
   else if(direction==-1 && inShortRetrInducZone) inducConfidence=1.0;
   else if(direction==-1 && !IsNa(pivH) && !IsNa(flipTop) && !IsNa(flipBot) &&
           pivH>flipBot && pivH<flipTop && !inShortRetrInducZone) inducConfidence=-0.5;

   expansionPreConvSeen     = preConvEvidence && obs_DecayScore>30;
   expansionInductionConf   = inductionEvidence;
   retracementPreConvSeen   = nearFlipzone && (bullMomDecay||bearMomDecay);
   retracementInductionConf = inRetracementInducZone || inShortRetrInducZone;
   expConvFormationActive   = convexityBelief>40 && expansionBelief>30;
   retrConvFormationActive  = convexityBelief>40 && retracementBelief>40;
   convexityComplete        = creationBelief>50 || absorptionBelief>40;

   flipzoneStagesComplete =
        (demandReturnBelief>75 && recursiveComplete) ? 5 :
        (demandReturnBelief>60) ? 4 :
        (retracementBelief>55) ? 3 :
        retracementInductionConf ? 2 :
        retracementPreConvSeen ? 1 : 0;
   flipzoneScore = flipzoneStagesComplete/5.0*100.0;
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/Erf.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  Erf.mqh - Energy Resolution Framework (EDE + RE + EAE)          |
//|            + V72 trade-readiness entry gate                      |
//|            + advisory FU order blocks / FRZ scoring              |
//|                                                                  |
//|  EDE : how energy is dissipating (state 1-6 from L0 phase)       |
//|  RE  : did the process finish? (RESOLVED/PARTIAL/UNRESOLVED)     |
//|  EAE : where unresolved energy pulls price (attractors)          |
//|  Gate: erf_entryGate = readiness >= threshold (gates entries)    |
//|                                                                  |
//|  Runs BETWEEN Obs_Compute and Liq_Compute (uses prev-bar         |
//|  convexityMaturity / cycle vars - the source forward-var lag).   |
//|                                                                  |
//|  FU order blocks and FRZ are advisory only (not wired into the   |
//|  entry gate), matching the source where they feed display only.  |
//+------------------------------------------------------------------+

//================= ERF OUTPUTS ====================================
int    ede_state=1;
string ede_cleaningState="Accumulating";
double ede_expansionEnergy=0, ede_dissipatedEnergy=0, ede_dissipationProgress=0, ede_deliverySpaceScore=0;
bool   ede_messyPriceIsDissipation=false, ede_liquidationBecomingDirectional=false;

int    re_expectedCycles=1, re_completedCycles=0;
double re_recursiveCompletionScore=0, re_residualEnergy=0, re_residualEnergyScore=0, re_revisitProbability=0;
bool   re_objectiveReached=false, re_fullDissipation=false, re_absorbedAndReturned=false, re_nodeOpen=true, re_nodeClosed=false;
string re_resolutionState="UNRESOLVED";

double eae_primaryAttractorPrice=PINE_NA, eae_secondaryAttractorPrice=PINE_NA;
double eae_primaryAttractorScore=0, eae_secondaryAttractorScore=0;
string eae_primaryAttractorLabel="No Active Attractor", eae_energyState="Accumulating";

double erf_confidence=0, erf_dissipationConfidence=0, erf_tradeReadiness=0;

//================= ADVISORY FU / FRZ ==============================
bool   fuBullDetected=false, fuBearDetected=false, fuActive=false;
int    fuLastDir=0; long fuLastBar=-1;
double frz_l0Score=0, frz_bestScore=0;

//==================================================================
void Erf_Init()
  {
   erf_entryGate=true; erf_suppressRotation=false;
   fuLastDir=0; fuLastBar=-1;
  }

//==================================================================
void Erf_Compute()
  {
   double cl=C_close(), hi=C_high(), lo=C_low(), op=C_open();
   double atrv=IsNa(atr)?0.0:atr;
   double effT=cfg_effThresh;

   //==================== EDE =====================================
   ede_state =
        (l0_phaseCanon=="Point 4 Origin") ? 1 :
        (l0_phaseCanon=="Expansion") ? 1 :
        (l0_phaseCanon=="Expansion Pre-Convexity") ? 2 :
        (l0_phaseCanon=="Expansion Induction") ? 3 :
        (l0_phaseCanon=="Expansion Liquidity") ? 4 :
        (l0_phaseCanon=="New High") ? 5 :
        (l0_phaseCanon=="New Low") ? 5 : 6;
   ede_cleaningState =
        ede_state==1?"Accumulating":ede_state==2?"Cleaning - Initial Release":
        ede_state==3?"Cleaning - Secondary Release":ede_state==4?"Cleaning - Purge":
        ede_state==5?"Delivering":"Resolving";
   ede_expansionEnergy = PineMin(obs_ExpansionScore*0.50+((bullImpulse||bearImpulse)?30.0:0.0)+efficiency*20.0,100.0);
   ede_dissipatedEnergy= PineMin((ede_state>=2?obs_DecayScore*0.40:0.0)+(ede_state>=3?obs_CurvatureScore*0.30:0.0)+(ede_state>=4?obs_LiquidityScore*0.30:0.0),100.0);
   ede_dissipationProgress=PineMin((ede_state>=2?25.0:0.0)+(ede_state>=3?25.0:0.0)+(ede_state>=4?25.0:0.0)+(ede_state>=5?25.0:0.0),100.0);
   ede_liquidationBecomingDirectional = (ede_state==4 && (bullImpulse||bearImpulse) && efficiency>effT*0.8);
   ede_deliverySpaceScore = PineMin(MathMax(0.0,100.0-convexityMaturity),100.0);
   ede_messyPriceIsDissipation = (ede_state>=2 && ede_state<=4) && obs_DecayScore>30.0 && efficiency<effT*0.9 && !(bullImpulse||bearImpulse);

   //==================== RE ======================================
   re_expectedCycles = (int)MathMax(1,MathMin(waveDepth+2,4));
   re_completedCycles= (int)MathMax(0,MathMin(entryCycle,re_expectedCycles));
   re_recursiveCompletionScore = re_expectedCycles>0 ? PineMin((double)re_completedCycles/(double)re_expectedCycles*100.0,100.0) : 0.0;
   re_residualEnergy = MathMax(0.0, ede_expansionEnergy-ede_dissipatedEnergy);
   re_objectiveReached = ede_state>=5;
   re_fullDissipation  = ede_dissipationProgress>=75.0;
   double re_dissipationProgress = ede_dissipationProgress;
   re_absorbedAndReturned = (ie1a_currentPhase=="Demand Return"||ie1a_currentPhase=="Supply Return") && recursiveComplete;
   re_resolutionState =
        (re_absorbedAndReturned && re_fullDissipation && re_recursiveCompletionScore>=75.0) ? "RESOLVED" :
        (re_objectiveReached && re_dissipationProgress>=50.0) ? "PARTIALLY RESOLVED" : "UNRESOLVED";
   re_residualEnergyScore = PineMin(re_residualEnergy,100.0);
   re_nodeOpen   = (re_resolutionState=="UNRESOLVED"||re_resolutionState=="PARTIALLY RESOLVED");
   re_nodeClosed = (re_resolutionState=="RESOLVED");
   re_revisitProbability =
        re_resolutionState=="UNRESOLVED" ? PineMin(re_residualEnergyScore*0.90,95.0) :
        re_resolutionState=="PARTIALLY RESOLVED" ? PineMin(re_residualEnergyScore*0.60,75.0) :
        PineMin(re_residualEnergyScore*0.20,25.0);

   //==================== EAE =====================================
   eae_primaryAttractorPrice =
        direction==0 ? PINE_NA :
        re_resolutionState=="UNRESOLVED" ? (direction==1?Nz(flipBot,cl-atrv*2.0):Nz(flipTop,cl+atrv*2.0)) :
        re_resolutionState=="PARTIALLY RESOLVED" ? (direction==1?Nz(point4OriginLow,cl-atrv):Nz(point4OriginHigh,cl+atrv)) : PINE_NA;
   eae_secondaryAttractorPrice =
        (direction!=0 && re_resolutionState=="UNRESOLVED" && !IsNa(inducZoneLow) && !IsNa(inducZoneHigh)) ?
        (direction==1?inducZoneLow:inducZoneHigh) : PINE_NA;
   eae_primaryAttractorScore = PineMin(
        re_residualEnergyScore*0.40 +
        (re_resolutionState=="UNRESOLVED"?30.0:re_resolutionState=="PARTIALLY RESOLVED"?20.0:5.0) +
        (!IsNa(eae_primaryAttractorPrice)?MathMax(0.0,30.0-MathAbs(cl-eae_primaryAttractorPrice)/MathMax(atrv,1e-10)*5.0):0.0),100.0);
   eae_secondaryAttractorScore = PineMin(
        re_residualEnergyScore*0.25 +
        (re_resolutionState=="PARTIALLY RESOLVED"?20.0:10.0) +
        (!IsNa(eae_secondaryAttractorPrice)?MathMax(0.0,20.0-MathAbs(cl-eae_secondaryAttractorPrice)/MathMax(atrv,1e-10)*4.0):0.0),100.0);
   eae_primaryAttractorLabel =
        re_resolutionState=="UNRESOLVED"?"Flip Zone (High Residual)":
        re_resolutionState=="PARTIALLY RESOLVED"?"Origin Zone (Partial)":"No Active Attractor";
   eae_energyState =
        ede_state==1?"Accumulating":(ede_state>=2&&ede_state<=4)?"Cleaning":ede_state==5?"Delivering":
        (re_resolutionState=="RESOLVED"?"Exhausted":"Resolving");

   //==================== ERF CONFIDENCE / GATE ===================
   erf_suppressRotation = ede_messyPriceIsDissipation && ede_state>=2 && ede_state<=4;
   erf_confidence = PineMin(
        (eae_energyState!="Accumulating"?ie1a_phaseConfidence*0.40:20.0) +
        (re_resolutionState=="RESOLVED"?30.0:re_resolutionState=="PARTIALLY RESOLVED"?20.0:10.0) +
        (eae_primaryAttractorScore*0.30),100.0);
   erf_dissipationConfidence = PineMin((ede_messyPriceIsDissipation?50.0:0.0)+ede_dissipationProgress*0.50,100.0);
   erf_tradeReadiness = PineMin(
        (re_resolutionState=="RESOLVED"?40.0:re_resolutionState=="PARTIALLY RESOLVED"?25.0:10.0) +
        re_recursiveCompletionScore*cfg_erfReadyResW +
        (100.0-re_residualEnergyScore)*cfg_erfReadyResidW +
        erf_confidence*cfg_erfReadyConfW,100.0);
   erf_entryGate = (!cfg_erfGateEnabled) || (erf_tradeReadiness>=cfg_erfEntryThresh);

   //==================== ADVISORY FU ORDER BLOCK =================
   double rng=hi-lo, body=MathAbs(cl-op);
   double bodyRatio=body/MathMax(rng,1e-10);
   double upWick=(hi-MathMax(op,cl))/MathMax(rng,1e-10);
   double dnWick=(MathMin(op,cl)-lo)/MathMax(rng,1e-10);
   bool inZoneOK = (!InpFuRequireInZone) || closeInside;
   fuBullDetected = (cl>op) && bodyRatio>=InpFuMinBodyRatio && dnWick>=InpFuMinWickRatio && inZoneOK;
   fuBearDetected = (cl<op) && bodyRatio>=InpFuMinBodyRatio && upWick>=InpFuMinWickRatio && inZoneOK;
   if(fuBullDetected){ fuLastDir=1; fuLastBar=g_barIndex; }
   else if(fuBearDetected){ fuLastDir=-1; fuLastBar=g_barIndex; }
   fuActive = (fuLastBar>=0) && ((g_barIndex-fuLastBar)<=InpFuMaxBarsActive);

   //==================== ADVISORY FRZ ============================
   frz_l0Score = g_se5.oFs;
   frz_bestScore = MathMax(g_se1.oFs,MathMax(g_se3.oFs,MathMax(g_se5.oFs,MathMax(g_se15.oFs,MathMax(g_se60.oFs,g_se240.oFs)))));
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/TimeIntel.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  TimeIntel.mqh - Time Intelligence Engine (TIE)                  |
//|                                                                  |
//|  Tracks each higher cycle (Monthly / Weekly / Daily / H4 / H1):  |
//|  is its high / low already taken, is it opening / expanding /    |
//|  mid / terminal, and which way it is biased from its open.       |
//|  Produces a cross-cycle timing read (timeDir / timeAlign /       |
//|  timeConflict) and the H1 timing call. This is CONTEXT for trade |
//|  management and timing - it does NOT gate the Letra entries.     |
//|                                                                  |
//|  Stateless per work bar: reads each cycle's running bar (shift 0)|
//|  and prior bar (shift 1) directly, so no feeder is required.     |
//+------------------------------------------------------------------+

//================= TIE OUTPUTS ====================================
int    timeDir=0;
double timeAlign=50.0, timeConflict=50.0;
string h1Timing="BALANCED";
double h1LowProb=50.0;

//--- per-cycle state (for management + dashboard)
bool   tMnHt=false,tMnLt=false, tWHt=false,tWLt=false, tDHt=false,tDLt=false, tH4Ht=false,tH4Lt=false, tH1Ht=false,tH1Lt=false;
int    tMnBias=0,tWBias=0,tDBias=0,tH4Bias=0,tH1Bias=0;
string tH1State="—", tH4State="—", tDState="—";

void TimeIntel_Init() {}

//--- cycle elapsed fraction 0..1
double TIE_Elapsed(const ENUM_TIMEFRAMES tf)
  {
   int per=PeriodSeconds(tf);
   if(per<=0) return 0.0;
   datetime ot=iTime(_Symbol,tf,0);
   if(ot==0) return 0.0;
   return Clamp((double)(TimeCurrent()-ot)/(double)per, 0.0, 1.0);
  }

string TIE_State(const bool ht,const bool lt,const double el)
  {
   if(ht && lt) return "DUAL DONE";
   if(ht)       return "HIGH DONE";
   if(lt)       return "LOW DONE";
   if(el<0.15)  return "OPENING";
   if(el<0.6)   return "EXPANDING";
   if(el<0.9)   return "MID CYCLE";
   return "TERMINAL";
  }

//--- evaluate one cycle: bias / high-taken / low-taken
void TIE_Cycle(const ENUM_TIMEFRAMES tf,const double cl,int &bias,bool &ht,bool &lt)
  {
   double o =iOpen (_Symbol,tf,0);
   double h =iHigh (_Symbol,tf,0);
   double lo=iLow  (_Symbol,tf,0);
   double ph=iHigh (_Symbol,tf,1);
   double pl=iLow  (_Symbol,tf,1);
   bias = cl>o?1:cl<o?-1:0;
   ht = (h>ph);
   lt = (lo<pl);
  }

void TimeIntel_Compute()
  {
   double cl=C_close();
   if(IsNa(cl)) return;

   TIE_Cycle(PERIOD_MN1, cl, tMnBias, tMnHt, tMnLt);
   TIE_Cycle(PERIOD_W1,  cl, tWBias,  tWHt,  tWLt);
   TIE_Cycle(PERIOD_D1,  cl, tDBias,  tDHt,  tDLt);
   TIE_Cycle(PERIOD_H4,  cl, tH4Bias, tH4Ht, tH4Lt);
   TIE_Cycle(PERIOD_H1,  cl, tH1Bias, tH1Ht, tH1Lt);

   tH1State = TIE_State(tH1Ht, tH1Lt, TIE_Elapsed(PERIOD_H1));
   tH4State = TIE_State(tH4Ht, tH4Lt, TIE_Elapsed(PERIOD_H4));
   tDState  = TIE_State(tDHt,  tDLt,  TIE_Elapsed(PERIOD_D1));

   int tBull = (tMnBias==1?1:0)+(tWBias==1?1:0)+(tDBias==1?1:0)+(tH4Bias==1?1:0)+(tH1Bias==1?1:0);
   int tBear = (tMnBias==-1?1:0)+(tWBias==-1?1:0)+(tDBias==-1?1:0)+(tH4Bias==-1?1:0)+(tH1Bias==-1?1:0);
   timeDir   = tBull>tBear ? 1 : tBear>tBull ? -1 : 0;
   timeAlign = (tBull+tBear)>0 ? (double)MathMax(tBull,tBear)/(tBull+tBear)*100.0 : 50.0;
   timeConflict = 100.0 - timeAlign;

   //--- H1 low-probability + timing call
   double h1O=iOpen(_Symbol,PERIOD_H1,0), h1H=iHigh(_Symbol,PERIOD_H1,0), h1L=iLow(_Symbol,PERIOD_H1,0);
   double pos=(cl-h1L)/MathMax(h1H-h1L, _Point);
   h1LowProb = (tH1Lt && !tH1Ht) ? 30.0 : (tH1Ht && !tH1Lt) ? 70.0 : MathRound(pos*100.0);
   h1Timing = (tH1Ht && tH1Lt) ? "COMPLETION" : h1LowProb>=55 ? "LOW FIRST" : h1LowProb<=45 ? "HIGH FIRST" : "BALANCED";
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/ScoringSignals.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  ScoringSignals.mqh - SECTIONS 15-24                            |
//|                                                                  |
//|  15 Scoring engine (contProb, grade)                            |
//|  16 Bayesian probabilistic model (finalProb)                    |
//|  17 Probability panels (expansion/reversal/readiness)           |
//|  18 Slippage & trade-opportunity engine (buy/sell score,        |
//|     net edge, edge filter)                                      |
//|  19 HTF alignment gate                                          |
//|  20 Adaptive execution lock                                     |
//|  21 Entry signals (long/short)                                  |
//|  24 Trade state engine (tradeDir, exit condition/latch)         |
//|                                                                  |
//|  Produces the final EA-facing signals consumed by TradeManager. |
//+------------------------------------------------------------------+

//================= EA-FACING SIGNAL OUTPUTS =======================
bool   sig_longSignal=false;
bool   sig_shortSignal=false;
bool   sig_exitNow=false;
int    sig_tradeDir=0;
double sig_finalProb=0.0;
string sig_grade="D";
double sig_netEdgeAdj=0.0;
string sig_directive="NO TRADE / STAND DOWN";

//================= INTERMEDIATE OUTPUTS (dashboard) ===============
double contProb=0.0; string grade="D";
double finalProb=0.0;
double expansionProbability=0,reversalProbability=0,tradeReadiness=0;
double buyScore=0,sellScore=0,netEdge=0,netEdgeAdjusted=0,buyProb=0,sellProb=0;
bool   edgePassesFilter=false;
string liveDirective="NEUTRAL / WAIT";
bool   htfAligned=false; int resonance=1;
bool   longSignal=false, shortSignal=false;
bool   exitCondition=false, exitLatchActive=false;
string directiveStr="NO TRADE / STAND DOWN";
double bayesFlipzone_g=0.0;

//================= PERSISTENT STATE ===============================
bool   engineArmed=true;
long   lastSignalBar=-1, lastLongBar=-1, lastShortBar=-1;
int    tradeDir=0;
long   exitFiredBar=-1;
double g_energyPrev=0.0;

//==================================================================
void Signals_Init()
  {
   engineArmed=true; lastSignalBar=-1; lastLongBar=-1; lastShortBar=-1;
   tradeDir=0; exitFiredBar=-1; g_energyPrev=0.0;
  }

//--- bayes logit helper
double Logit(const double p){ double pp=MathMax(p,1e-10); return MathLog(pp/MathMax(1.0-p,1e-10)); }

//==================================================================
void Signals_Compute()
  {
   double cl=C_close();
   double atrv=IsNa(atr)?0.0:atr;
   double effT=cfg_effThresh, dispT=cfg_dispThresh;

   //==================== SECTION 15 - SCORING ====================
   double poiMid = (!IsNa(flipTop)&&!IsNa(flipBot)) ? (flipTop+flipBot)/2.0 : PINE_NA;
   double energy = (!IsNa(poiMid)) ? MathAbs(cl-poiMid)/MathMax(atrv,1e-10) : 0.0;
   double sStruct = flipzoneScore*0.30;
   double sConv   = PineMin(MathAbs(convSmooth)/MathMax(atrv*cfg_convMult,1e-10)*25.0,25.0);
   double sEnergy = PineMin(energy*10.0,20.0);
   double sEff    = efficiency*15.0;
   double sVol    = PineMin(atrv/MathMax(cl,1e-10)*1000.0,10.0);
   contProb = PineMin(sStruct+sConv+sEnergy+sEff+sVol,100.0);
   grade = contProb>90 ? "A+" : contProb>80 ? "A" : contProb>70 ? "B" : contProb>60 ? "C" : "D";

   //==================== SECTION 16 - BAYESIAN ===================
   double bayesStruct   = (structBias==liveWaveDir) ? 0.90 : (structBias==0 ? 0.50 : 0.15);
   double bayesMomentum = (liveWaveDir==1 && velocity>0 && acceleration>0) ? 0.85 :
                          (liveWaveDir==-1 && velocity<0 && acceleration<0) ? 0.85 :
                          ((liveWaveDir==1 && velocity>0)||(liveWaveDir==-1 && velocity<0)) ? 0.60 : 0.30;
   double bayesLiq      = liqHeat>70 ? 0.80 : liqHeat>30 ? 0.55 : 0.35;
   double bayesHTF      = (liveHtfAlign==liveWaveDir && liveHtfAlign!=0) ? 0.90 : (liveHtfAlign==0 ? 0.55 : 0.20);
   double bayesDisp     = displacement>dispT*1.5 ? 0.85 : displacement>dispT ? 0.65 : 0.35;
   double bayesOB       = obFreshness>0.7 ? 0.80 : obFreshness>0.4 ? 0.60 : 0.35;
   double bayesInduc    = inducConfidence>0 ? 0.90 : inducConfidence<0 ? 0.20 : 0.50;
   double bayesFlipzone = flipzoneStagesComplete>=4 ? 0.92 : flipzoneStagesComplete>=3 ? 0.75 :
                          flipzoneStagesComplete>=2 ? 0.58 : flipzoneStagesComplete>=1 ? 0.42 : 0.25;
   bayesFlipzone_g=bayesFlipzone;

   double logOdds =
        0.15*Logit(bayesStruct)+0.14*Logit(bayesMomentum)+0.10*Logit(bayesLiq)+0.14*Logit(bayesHTF)+
        0.11*Logit(bayesDisp)+0.07*Logit(bayesOB)+0.12*Logit(bayesInduc)+0.17*Logit(bayesFlipzone);
   finalProb = 1.0/(1.0+MathExp(-logOdds))*100.0;

   //==================== SECTION 17 - PROB PANELS ================
   double velDecay = phys_vd70 ? 1.0 : 0.0;
   expansionProbability = PineMin(
        ((!bullInvalid && !bearInvalid)?20.0:0.0) +
        (convexityComplete?20.0:convexityScore*0.4) +
        (recursiveComplete?15.0:flipzoneStagesComplete*3.0) +
        ((liveHtfAlign==liveWaveDir && liveHtfAlign!=0)?25.0:(liveHtfAlign==0?12.5:0.0)) +
        (liqHeat>50?20.0:liqHeat*0.4), 100.0);
   reversalProbability = PineMin(
        (convexityScore>70?25.0:convexityScore*0.35) +
        (retracementInductionConf?20.0:0.0) +
        (liqHeat>70?20.0:0.0) +
        (velDecay*20.0) +
        ((liveHtfAlign!=liveWaveDir && liveHtfAlign!=0)?15.0:0.0), 100.0);
   tradeReadiness = PineMin(
        (liveWaveDir!=0?10.0:0.0) +
        (flipzoneStagesComplete>=3?15.0:flipzoneStagesComplete*5.0) +
        (velocityScore*0.10) +
        (expansionScore*0.10) +
        (liqHeat<50?10.0:(liqHeat>70?-5.0:0.0)) +
        ((liveHtfAlign==liveWaveDir && liveHtfAlign!=0)?15.0:0.0) +
        (expansionProbability*0.20) +
        (bayesFlipzone*3.0), 100.0);

   //==================== SECTION 18 - OPPORTUNITY ================
   double spreadEstimate   = atrv*0.05;
   double volatilityFactor = phys_volRatio*0.10;
   double slippageCost     = atrv*volatilityFactor+spreadEstimate;
   double liqDepthPenalty  = liqHeat>70 ? atrv*0.05 : 0.0;
   double totalSlippage    = slippageCost+liqDepthPenalty;

   double baseTrend     = efficiency*30.0;
   double impulseScore  = displacement>dispT ? 20.0 : 0.0;
   double momentum      = phys_mom;
   double momentumScore = momentum>0 ? 10.0 : -10.0;
   double accelScore    = acceleration>0 ? 10.0 : -10.0;
   double structScore   = structBias==1 ? 20.0 : structBias==-1 ? -20.0 : 0.0;
   double htfScore      = htfAlign==1 ? 20.0 : htfAlign==-1 ? -20.0 : 0.0;
   double liqScoreV     = wDensity<0.5 ? 10.0 : -5.0;
   double zoneScore     = closeInside ? 15.0 : 0.0;
   double inducScore    = inducConfidence>0 ? 10.0 : inducConfidence<0 ? -10.0 : 0.0;
   double fzStageScore  = flipzoneStagesComplete*6.0;
   double beliefBonus   = (direction==1 && demandReturnBelief>60) ? demandReturnBelief*0.10 :
                          (direction==-1 && demandReturnBelief>60) ? demandReturnBelief*0.10 : 0.0;
   double confMult      = MathMax(0.7, MathMin(modelConfidence/100.0*1.3, 1.3));

   buyScore =
        (baseTrend+impulseScore+
         MathMax(momentumScore,0)+MathMax(accelScore,0)+
         MathMax(structScore,0)+MathMax(htfScore,0)+
         liqScoreV+zoneScore+MathMax(inducScore,0)+fzStageScore+beliefBonus+
         (fractalStackDir==1 ? fractalCtxScore*0.30 : 0.0))*confMult;
   sellScore =
        (baseTrend+impulseScore+
         MathMax(-momentumScore,0)+MathMax(-accelScore,0)+
         MathMax(-structScore,0)+MathMax(-htfScore,0)+
         liqScoreV+zoneScore+MathMax(-inducScore,0)+fzStageScore+beliefBonus+
         (fractalStackDir==-1 ? fractalCtxScore*0.30 : 0.0))*confMult;

   netEdge         = buyScore-sellScore;
   netEdgeAdjusted = netEdge-(totalSlippage/MathMax(atrv,1e-10)*10.0);
   edgePassesFilter= MathAbs(netEdgeAdjusted)>cfg_execThreshold;

   double BSMAX=279.5;
   buyProb  = Clamp(buyScore /BSMAX*100.0,0.0,100.0);
   sellProb = Clamp(sellScore/BSMAX*100.0,0.0,100.0);

   liveDirective = netEdgeAdjusted>25 ? "BUY PRESSURE" : netEdgeAdjusted>10 ? "BULLISH BIAS" :
                   netEdgeAdjusted<-25 ? "SELL PRESSURE" : netEdgeAdjusted<-10 ? "BEARISH BIAS" : "NEUTRAL / WAIT";

   //==================== SECTION 19 - HTF GATE ===================
   htfAligned = (direction!=0) && (htfAlign==direction || htfAlign==0);
   resonance  = htfAligned ? 2 : 1;

   //==================== SECTION 20 - EXEC LOCK ==================
   int dynamicLockBars = PineRound(cfg_baseLockBars*phys_volMult);
   bool inducRearmLong  = (direction==1  && inRetracementInducZone);
   bool inducRearmShort = (direction==-1 && inShortRetrInducZone);
   if(recursiveJustFired) engineArmed=true;
   if(inducRearmLong||inducRearmShort) engineArmed=true;

   bool withinGlobalLock = (lastSignalBar>=0) && ((g_barIndex-lastSignalBar)<dynamicLockBars);
   bool withinLongLock   = (lastLongBar>=0)   && ((g_barIndex-lastLongBar)<dynamicLockBars);
   bool withinShortLock  = (lastShortBar>=0)  && ((g_barIndex-lastShortBar)<dynamicLockBars);
   bool signalLocked     = withinGlobalLock && !engineArmed;

   bool htfLongOK  = (!cfg_requireHTFAlign) || (htfBias1>=0 && htfBias2>=0);
   bool htfShortOK = (!cfg_requireHTFAlign) || (htfBias1<=0 && htfBias2<=0);
   bool preConvOK_long  = (!cfg_requirePreConv)   || retracementPreConvSeen;
   bool preConvOK_short = (!cfg_requirePreConv)   || retracementPreConvSeen;
   bool inducOK_long    = (!cfg_requireInduction) || retracementInductionConf;
   bool inducOK_short   = (!cfg_requireInduction) || retracementInductionConf;

   //==================== SECTION 21 - ENTRY SIGNALS =============
   bool gradeOK = (!cfg_useGradeFilter) ? true :
        (cfg_useStrictStruct ? (grade=="A+"||grade=="A"||grade=="B")
                             : (grade=="A+"||grade=="A"||grade=="B"||grade=="C"));

   bool beliefEntryLong  = (direction==1)  && (ie1a_currentPhase=="Demand Return") &&
                           demandReturnBelief>50 && expansionBelief<60 && absorptionBelief>25;
   bool beliefEntryShort = (direction==-1) && (ie1a_currentPhase=="Supply Return") &&
                           demandReturnBelief>50 && expansionBelief<60 && absorptionBelief>25;

   longSignal = cfg_showSignals && beliefEntryLong && htfAligned && gradeOK &&
                !signalLocked && !withinLongLock && edgePassesFilter &&
                preConvOK_long && inducOK_long && structLongOK && liqSweepOK && obFresh && htfLongOK && erf_entryGate;
   shortSignal= cfg_showSignals && beliefEntryShort && htfAligned && gradeOK &&
                !signalLocked && !withinShortLock && edgePassesFilter &&
                preConvOK_short && inducOK_short && structShortOK && liqSweepOK && obFresh && htfShortOK && erf_entryGate;

   if(longSignal){ lastSignalBar=g_barIndex; lastLongBar=g_barIndex; engineArmed=false; }
   if(shortSignal){ lastSignalBar=g_barIndex; lastShortBar=g_barIndex; engineArmed=false; }

   //==================== SECTION 24 - TRADE STATE ===============
   //  V60 14-phase vocabulary: the move "dying" is Transition (was Absorption);
   //  Retracement still signals the counter-leg taking over.
   bool phaseAbsRetr = (ie1a_currentPhase=="Transition"||ie1a_currentPhase=="Retracement");
   exitCondition =
        (tradeDir==1 && bearBOS) || (tradeDir==-1 && bullBOS) ||
        (tradeDir==1 && bearConvShift && energy<g_energyPrev) ||
        (tradeDir==-1 && bullConvShift && energy<g_energyPrev) ||
        (tradeDir==1 && htfAlign==-1) || (tradeDir==-1 && htfAlign==1) ||
        (tradeDir!=0 && !obFresh) || (tradeDir!=0 && safeToReset) ||
        (tradeDir==1 && bullInvalid) || (tradeDir==-1 && bearInvalid) ||
        (tradeDir==1 && phaseAbsRetr) || (tradeDir==-1 && phaseAbsRetr);

   if(longSignal){ tradeDir=1; exitFiredBar=-1; }
   else if(shortSignal){ tradeDir=-1; exitFiredBar=-1; }
   else if(exitCondition && tradeDir!=0){ exitFiredBar=g_barIndex; tradeDir=0; }

   exitLatchActive = (exitFiredBar>=0) && ((g_barIndex-exitFiredBar)<3);

   directiveStr = longSignal ? "BUY  (ENTER LONG)" :
                  shortSignal ? "SELL  (ENTER SHORT)" :
                  exitLatchActive ? "EXIT NOW" :
                  tradeDir==1 ? "HOLD LONG" :
                  tradeDir==-1 ? "HOLD SHORT" : "NO TRADE / STAND DOWN";

   //--- publish EA-facing signals
   sig_longSignal = longSignal;
   sig_shortSignal= shortSignal;
   sig_exitNow    = exitLatchActive;
   sig_tradeDir   = tradeDir;
   sig_finalProb  = finalProb;
   sig_grade      = grade;
   sig_netEdgeAdj = netEdgeAdjusted;
   sig_directive  = directiveStr;

   //--- energy[1] for next bar
   g_energyPrev = energy;
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/CurveTree.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  CurveTree.mqh - F72 literal recursive curve tree                |
//|                                                                  |
//|  Recursion is EVENT-generated, not timeframe-generated: a        |
//|  Phase-2 CHoCH against the owning curve spawns a CHILD curve     |
//|  (same lifecycle, opposite orientation). Every node is just      |
//|  another curve (Principle 1/12).                                 |
//|                                                                  |
//|   * Ownership (Principle 8) = the shallowest curve that still    |
//|     holds energy; a child only takes over once the parent        |
//|     dissipates below the energy floor.                           |
//|   * Energy dynamics: a node gains energy while it keeps making   |
//|     progress (continuation) and decays when it stalls; at zero   |
//|     it dies (merges back into the parent).                       |
//|   * Recursion BUDGET (Principle 3/4) from compression: wide      |
//|     curve -> ~1 deep recursion; failure-swing (high compression) |
//|     -> up to 4 tiny ones. A CHoCH only spawns a child while the  |
//|     budget has room.                                             |
//|   * FU-MERGE / ownership transfer (Principle 9): a counter child |
//|     that respects the parent FU flip and reacts (does not break  |
//|     it) MERGES back into the parent (Camp B -> Camp A, parent     |
//|     campaign continues); one that BREAKS the parent flip is a     |
//|     genuine handoff (TRANSFERRED, new campaign).                  |
//|   * Each node emits an EMERGENT phase from its own energy /       |
//|     maturity / depth (curve -> phase, Principle 1).               |
//|                                                                  |
//|  The tree owner is the authoritative "which curve owns price"    |
//|  read consumed by the ownership / curve-life engines.            |
//+------------------------------------------------------------------+

//================= NODE TYPE ======================================
struct CurveNode
  {
   int    id;
   int    parent;
   int    dir;
   double origin;
   double extreme;
   double energy;
   bool   alive;
   int    depth;
   string state;
   long   bar;
   double comp;
   double mat;
   int    srcTf;     // 0 = chart/M5
  };

//================= TREE OUTPUTS ===================================
int    ct_treeAlive=0, ct_treeDepth=0, ct_budgetDepth=1;
int    ct_ownDir=0, ct_ownDepth=0;
double ct_ownEnergy=0.0, ct_ownOrig=PINE_NA, ct_ownExt=PINE_NA;
string ct_ownState="-";
bool   ct_merged=false, ct_transferred=false;
string ct_ownStateTx="aligned with parent";
int    ct_childDir=0, ct_parentDir=0;

//--- internal state
CurveNode g_tree[];
int  g_nodeSeq=0;
double g_ct_prevInv=PINE_NA;   // detect M5 wave-origin change
long   g_ct_bar5=0;
double g_ownMinE=12.0;

void CurveTree_Init()
  {
   ArrayResize(g_tree,0);
   g_nodeSeq=0; g_ct_prevInv=PINE_NA; g_ct_bar5=0;
  }

//--- emergent phase from a node's own energy / maturity / depth
string NodeState(const int d,const double e,const int dep,const double cmp,const double mat)
  {
   if(dep>0)
      return e>=70.0 ? "Transition - recursive expansion" :
             e>=40.0 ? "Transition - recursive induction" : "Transition - recursive liquidation";
   if(mat<12.0) return "Point 4 Origin";
   if(e>=78.0 && mat>=70.0) return d==1 ? "New High" : d==-1 ? "New Low" : "Climax";
   if(mat<35.0) return "Expansion";
   if(mat<55.0) return "Expansion Pre-Convexity";
   if(e>=55.0)  return "Expansion Induction";
   if(e>=35.0)  return "Expansion Liquidity";
   if(cmp>=60.0) return "Retracement Pre-Convexity";
   if(e>=18.0)  return "Retracement Induction";
   return "Retracement";
  }

void CurveTree_Compute()
  {
   double cl=C_close(), op=C_open(), hi=C_high(), lo=C_low();

   //--- track the bar the M5 wave origin last changed (so a curve box/age spans its own leg)
   if(IsNa(g_ct_prevInv) || se5_inv!=g_ct_prevInv){ g_ct_bar5=g_barIndex; g_ct_prevInv=se5_inv; }

   int n=ArraySize(g_tree);

   //--- pre-owner (Principle 8): shallowest alive node with energy; fallback highest energy
   int    preOwn=-1; double preE=-1.0; int preDepth=999;
   for(int i=0;i<n;i++)
     {
      if(g_tree[i].alive && g_tree[i].energy>=g_ownMinE &&
         (g_tree[i].depth<preDepth || (g_tree[i].depth==preDepth && g_tree[i].energy>preE)))
        { preDepth=g_tree[i].depth; preE=g_tree[i].energy; preOwn=i; }
     }
   if(preOwn<0)
      for(int i=0;i<n;i++)
         if(g_tree[i].alive && g_tree[i].energy>preE){ preE=g_tree[i].energy; preOwn=i; }

   //--- context anchor = chart (M5) wave
   int    ctxDir = l0_dir;
   double ctxOrig= se5_inv;
   double ctxExt = ctxDir==1 ? MathMax(Nz(cycleHigh,hi),hi) : ctxDir==-1 ? MathMin(Nz(cycleLow,lo),lo) : cl;

   //--- seed / re-seed the root when no living curve owns price
   if(preOwn<0 && ctxDir!=0 && !IsNa(ctxOrig))
     {
      g_nodeSeq++;
      int idx=ArraySize(g_tree); ArrayResize(g_tree, idx+1);
      g_tree[idx].id=g_nodeSeq; g_tree[idx].parent=-1; g_tree[idx].dir=ctxDir;
      g_tree[idx].origin=ctxOrig; g_tree[idx].extreme=ctxExt;
      g_tree[idx].energy=MathMax(40.0, Nz(ede_expansionEnergy,60.0));
      g_tree[idx].alive=true; g_tree[idx].depth=0; g_tree[idx].state="Expansion";
      g_tree[idx].bar=g_barIndex; g_tree[idx].comp=se5_comp; g_tree[idx].mat=se5_wp; g_tree[idx].srcTf=0;
      n=ArraySize(g_tree);
     }

   //--- recursion budget from compression (Principle 3/4)
   double gComp=se5_comp;
   ct_budgetDepth=(int)MathMax(1.0, MathMin(4.0, 1.0+MathRound(gComp/33.0)));

   //--- event-generated CHILD: a chart-TF Phase-2 CHoCH against the owner spawns
   //    an inverse curve while the recursion budget has room.
   if(preOwn>=0)
     {
      int pd=g_tree[preOwn].dir; int pdep=g_tree[preOwn].depth; int pid=g_tree[preOwn].id;
      bool counterCH=(pd==1 && bearCHoCH)||(pd==-1 && bullCHoCH);
      if(counterCH && (pdep+1<=ct_budgetDepth))
        {
         g_nodeSeq++;
         int idx=ArraySize(g_tree); ArrayResize(g_tree, idx+1);
         g_tree[idx].id=g_nodeSeq; g_tree[idx].parent=pid; g_tree[idx].dir=-pd;
         g_tree[idx].origin=cl; g_tree[idx].extreme=cl;
         g_tree[idx].energy=MathMax(25.0, Nz(ede_expansionEnergy,50.0)*0.85);
         g_tree[idx].alive=true; g_tree[idx].depth=pdep+1; g_tree[idx].state="Transition - recursive expansion";
         g_tree[idx].bar=g_barIndex; g_tree[idx].comp=se5_comp; g_tree[idx].mat=se5_wp; g_tree[idx].srcTf=0;
         n=ArraySize(g_tree);
        }
     }

   //--- update living nodes
   for(int i=0;i<n;i++)
     {
      if(!g_tree[i].alive) continue;
      if(g_tree[i].depth==0)
        {
         //--- root mirrors the chart wave (dir / origin / extreme / bar)
         g_tree[i].dir=l0_dir;
         g_tree[i].bar=g_ct_bar5;
         double prevExt=g_tree[i].extreme;
         bool prog = g_tree[i].dir==1 ? (hi>Nz(prevExt,hi)) : (lo<Nz(prevExt,lo));
         g_tree[i].origin=se5_inv;
         g_tree[i].extreme=g_tree[i].dir==1 ? se5_sh : se5_sl;
         g_tree[i].energy=prog ? MathMin(100.0,g_tree[i].energy+7.0) : MathMax(0.0,g_tree[i].energy-2.0);
        }
      else
        {
         double prevExt=g_tree[i].extreme;
         bool prog = g_tree[i].dir==1 ? (hi>Nz(prevExt,hi)) : (lo<Nz(prevExt,lo));
         g_tree[i].extreme=g_tree[i].dir==1 ? MathMax(Nz(prevExt,hi),hi) : MathMin(Nz(prevExt,lo),lo);
         g_tree[i].energy=prog ? MathMin(100.0,g_tree[i].energy+7.0) : MathMax(0.0,g_tree[i].energy-2.0);
        }
      g_tree[i].mat = se5_wp;
      g_tree[i].comp= se5_comp;
      g_tree[i].state=NodeState(g_tree[i].dir, g_tree[i].energy, g_tree[i].depth, g_tree[i].comp, g_tree[i].mat);
      if(g_tree[i].energy<=2.0) g_tree[i].alive=false;
     }

   //--- cap tree size
   while(ArraySize(g_tree)>60) ArrayRemove(g_tree,0,1);
   n=ArraySize(g_tree);

   //--- summary + final owner (Principle 8)
   ct_treeAlive=0; ct_treeDepth=0;
   int ownF=-1; double ownFE=-1.0; int ownDepth=999;
   for(int i=0;i<n;i++)
     {
      if(!g_tree[i].alive) continue;
      ct_treeAlive++;
      if(g_tree[i].depth>ct_treeDepth) ct_treeDepth=g_tree[i].depth;
      if(g_tree[i].energy>=g_ownMinE && (g_tree[i].depth<ownDepth || (g_tree[i].depth==ownDepth && g_tree[i].energy>ownFE)))
        { ownDepth=g_tree[i].depth; ownFE=g_tree[i].energy; ownF=i; }
     }
   if(ownF<0)
      for(int i=0;i<n;i++)
         if(g_tree[i].alive && g_tree[i].energy>ownFE){ ownFE=g_tree[i].energy; ownF=i; }

   if(ownF>=0)
     {
      ct_ownDir=g_tree[ownF].dir; ct_ownDepth=g_tree[ownF].depth; ct_ownEnergy=g_tree[ownF].energy;
      ct_ownState=g_tree[ownF].state; ct_ownOrig=g_tree[ownF].origin; ct_ownExt=g_tree[ownF].extreme;
     }
   else
     { ct_ownDir=0; ct_ownDepth=0; ct_ownEnergy=0.0; ct_ownState="-"; ct_ownOrig=PINE_NA; ct_ownExt=PINE_NA; }

   //--- FU-MERGE / ownership transfer (Principle 9)
   ct_childDir = l0_dir;
   ct_parentDir = (l2_dir+l4_dir)!=0 ? ((l2_dir+l4_dir)>0?1:-1) : l1_dir;
   bool counterChild = (ct_childDir!=0 && ct_parentDir!=0 && ct_childDir!=ct_parentDir);
   double pFlipTop = (!IsNa(se60_ft)&&!IsNa(se60_fb)) ? MathMax(se60_ft,se60_fb) : PINE_NA;
   double pFlipBot = (!IsNa(se60_ft)&&!IsNa(se60_fb)) ? MathMin(se60_ft,se60_fb) : PINE_NA;
   bool atParentFU = (!IsNa(pFlipTop)&&!IsNa(pFlipBot)&&hi>=pFlipBot&&lo<=pFlipTop);
   bool reactPar = ct_parentDir==1 ? (bullImpulse||cl>op) : ct_parentDir==-1 ? (bearImpulse||cl<op) : false;
   bool brokePar = (!IsNa(pFlipBot)&&!IsNa(pFlipTop)) && (ct_parentDir==1 ? cl<pFlipBot : ct_parentDir==-1 ? cl>pFlipTop : false);
   ct_merged     = counterChild && atParentFU && reactPar && !brokePar;
   ct_transferred= counterChild && brokePar;
   ct_ownStateTx = ct_transferred ? "TRANSFERRED - new campaign" :
                   ct_merged ? "MERGED -> parent (B->A)" :
                   counterChild ? "child recursion active" : "aligned with parent";
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/CurveOwnership.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  CurveOwnership.mqh - F72 Recursive Curve Ownership Engine       |
//|                                                                  |
//|  Reframes the lifecycle the way the framework actually behaves:  |
//|  markets are curves inside curves, and a New High is NOT an      |
//|  endpoint - it opens a recursive TRANSITION environment that     |
//|  completes only when dominance transfers to the recursive wave.  |
//|  The 14-phase structure engine already models the recursive      |
//|  transition (recBrk / recDom / transfer); this engine adds the   |
//|  higher-order layer the eye actually tracks:                     |
//|                                                                  |
//|   1. Who owns price (which timeframe curve is mid-progress)      |
//|   2. Campaign: BUILDING (expansion side) vs TERMINAL (HTF zone)  |
//|   3. Remaining CURVE BUDGET = distance-to-HTF-zone / convexity / |
//|      compression  ->  how many recursive cycles are physically   |
//|      possible (Principle 4)                                      |
//|   4. Dominance transfer % (old wave vs recursive wave)           |
//|   5. The MASTER distinction: BUILDING vs ENTRY CYCLE, and an     |
//|      entry-readiness ladder (NOT READY -> ... -> ENTRY ACTIVE    |
//|      -> TERMINAL). Confusing 'first strike' with 'entry cycle'   |
//|      is what liquidates traders.                                 |
//|   6. Participant interference (0.618/0.70/0.786) vs the FLIP     |
//|      (true induction at the lowest flip).                        |
//|                                                                  |
//|  Compression only matters in TERMINAL regions (Principle 8).     |
//|  This engine is CONTEXT + management input; it never gates the   |
//|  precise Letra entry trigger and adds no conflict safety.        |
//+------------------------------------------------------------------+

//================= OWNERSHIP OUTPUTS ==============================
string co_campaign="BUILDING";        // BUILDING | TERMINAL
string co_location="BUILDING";        // BUILDING | TRANSITIONING | APPROACHING HTF ZONE | INSIDE HTF ZONE
string co_compRegime="WIDE";          // WIDE | MEDIUM | COMPRESSED | FAILURE SWING
double co_remainingBudget=100.0;      // 0..100 (room left toward HTF zone, in wavelengths)
int    co_expectedDepth=1;            // physically-possible recursive cycles (1..4)
int    co_recDepth=0;                 // recursive cycles seen so far (Phase-2 CHoCH count)
double co_oldPct=100.0, co_newPct=0.0;// dominance: old wave vs recursive wave
bool   co_transferComplete=false;
double co_transitionMaturity=0.0;     // 0..100
string co_buildingVsEntry="BUILDING"; // BUILDING | ENTRY  (the master distinction)
string co_entryReadiness="NOT READY"; // NOT READY|EARLY|BUILDING|PRE-ENTRY|ENTRY ACTIVE|TERMINAL
string co_ownerLabel="-";             // which TF curve owns price
bool   co_insideHTF=false;
double co_htfTop=PINE_NA, co_htfBot=PINE_NA;
//--- participant interference vs the flip (true induction)
double co_f618=PINE_NA, co_f70=PINE_NA, co_f786=PINE_NA, co_flipLvl=PINE_NA;
string co_partZone="-";

void CurveOwnership_Init() {}

void CurveOwnership_Compute()
  {
   double cl=C_close();
   double atrv=IsNa(atr)?0.0:atr;
   int    dir=l0_dir;
   string phase=ie1a_currentPhase;

   //--- active HTF flip zone (H4 preferred, else H1; else HTF swing extreme)
   double top = (!IsNa(se240_ft)) ? se240_ft : se60_ft;
   double bot = (!IsNa(se240_fb)) ? se240_fb : se60_fb;
   if(IsNa(top) || IsNa(bot))
     {
      double sw = dir==1 ? se240_sh : dir==-1 ? se240_sl : PINE_NA;
      if(!IsNa(sw)){ top=sw; bot=sw; }
     }
   co_htfTop=top; co_htfBot=bot;
   double bandHi = (!IsNa(top)&&!IsNa(bot)) ? MathMax(top,bot) : PINE_NA;
   double bandLo = (!IsNa(top)&&!IsNa(bot)) ? MathMin(top,bot) : PINE_NA;
   double pad = atrv*0.25;
   co_insideHTF = (!IsNa(bandHi)&&!IsNa(bandLo)&&cl<=bandHi+pad&&cl>=bandLo-pad);
   double mid = (!IsNa(bandHi)&&!IsNa(bandLo)) ? (bandHi+bandLo)/2.0 : PINE_NA;
   double distATR = IsNa(mid) ? PINE_NA : MathAbs(cl-mid)/MathMax(atrv,1e-10);

   //--- compression regime (Principle 8: meaningful in terminal regions)
   double comp = se5_comp;
   co_compRegime = comp<25.0 ? "WIDE" : comp<50.0 ? "MEDIUM" : comp<75.0 ? "COMPRESSED" : "FAILURE SWING";

   //--- remaining curve budget = distance(wavelengths) toward HTF zone
   double convW = (!IsNa(se5_ft)&&!IsNa(se5_fb)) ? MathAbs(se5_ft-se5_fb) : atrv;
   double convATR = MathMax(convW/MathMax(atrv,1e-10), 0.3);
   double rcbWaves = IsNa(distATR) ? 6.0 : distATR/convATR;
   co_remainingBudget = Clamp(rcbWaves/6.0*100.0, 0.0, 100.0);

   //--- terminal-phase / inside-zone test
   bool termPhase = (phase=="HTF Flip Zone"||phase=="Induction"||phase=="Liquidation"||
                     phase=="Terminal Curve"||phase=="Demand Return"||phase=="Supply Return");
   bool terminal = co_insideHTF || termPhase;
   co_campaign = terminal ? "TERMINAL" : "EXPANSION";

   //--- expected recursive depth (Principle 4 + Wyckoff 4-shift):
   //    terminal -> compression drives count (compressed=more/smaller loops);
   //    building -> compression-only heuristic.
   if(terminal)
      co_expectedDepth = comp>=75.0 ? 4 : comp>=50.0 ? 3 : comp>=25.0 ? 2 : 1;
   else
      co_expectedDepth = (int)MathMax(1.0, MathMin(4.0, 1.0+MathRound(comp/33.0)));

   //--- recursion depth + dominance transfer (from the curve tree + structure engine)
   co_recDepth = ct_treeDepth;
   co_newPct = Clamp(se5_dom, 0.0, 100.0);
   co_oldPct = 100.0-co_newPct;
   co_transferComplete = co_newPct>=50.0;
   co_transitionMaturity = Clamp(MathMax(co_newPct, co_expectedDepth>0 ? (double)co_recDepth/co_expectedDepth*100.0 : 0.0), 0.0, 100.0);

   //--- location
   co_location = co_insideHTF ? "INSIDE HTF ZONE" :
                 (!IsNa(distATR)&&distATR<2.0) ? "APPROACHING HTF ZONE" :
                 (phase=="Transition"||phase=="Retracement") ? "TRANSITIONING" : "BUILDING";

   //--- BUILDING vs ENTRY CYCLE (the master distinction)
   bool firstStrike = co_insideHTF && co_recDepth==0;
   bool entryActive = (co_insideHTF && co_recDepth>=2) || (co_insideHTF && co_transferComplete) ||
                      phase=="Liquidation" || phase=="Terminal Curve";
   co_buildingVsEntry = entryActive ? "ENTRY" : "BUILDING";

   co_entryReadiness =
        (phase=="Liquidation"||phase=="Terminal Curve") ? "TERMINAL" :
        entryActive ? "ENTRY ACTIVE" :
        (co_insideHTF && co_recDepth>=1) ? "PRE-ENTRY" :
        firstStrike ? "BUILDING" :
        (!IsNa(distATR)&&distATR<2.0) ? "EARLY" : "NOT READY";

   //--- owner timeframe (highest TF whose wave is mid-progress)
   co_ownerLabel = (se240_wp>10.0&&se240_wp<90.0) ? "H4" :
                   (se60_wp>10.0&&se60_wp<90.0) ? "H1" :
                   (se5_wp>10.0&&se5_wp<90.0) ? "M5" : "-";

   //--- participant interference vs the flip (true induction at lowest flip)
   double ext  = dir==1 ? se5_sh : dir==-1 ? se5_sl : PINE_NA;
   double orig = se5_inv;
   double rng  = (!IsNa(ext)&&!IsNa(orig)) ? (ext-orig) : PINE_NA;
   co_f618 = IsNa(rng) ? PINE_NA : ext-0.618*rng;
   co_f70  = IsNa(rng) ? PINE_NA : ext-0.70 *rng;
   co_f786 = IsNa(rng) ? PINE_NA : ext-0.786*rng;
   co_flipLvl = dir==1 ? se5_fb : dir==-1 ? se5_ft : PINE_NA;
   double retrAbs = (!IsNa(rng)&&MathAbs(rng)>1e-10) ? MathAbs(ext-cl)/MathAbs(rng) : PINE_NA;
   co_partZone = IsNa(retrAbs) ? "-" :
        retrAbs<0.55 ? "pre-0.618 clean" :
        retrAbs<0.66 ? "0.618 participants" :
        retrAbs<0.74 ? "0.70 interference" :
        retrAbs<0.82 ? "0.786 heavy" : "FLIP true induction";
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/MtfOwnership.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  MtfOwnership.mqh - Multi-Timeframe Curve Ownership Engine       |
//|                                                                  |
//|  Principle 12/14, Priority Level 1: every timeframe runs its own |
//|  recursive curve simultaneously (M1..H4). This engine reads each |
//|  rung's own curve state (direction, wave progress, compression,  |
//|  recursion count, dominance transfer) and rolls them into the    |
//|  single question that matters most:                              |
//|                                                                  |
//|    WHICH CURVE CURRENTLY OWNS PRICE  (H4 70% / H1 20% / M5 10%)  |
//|                                                                  |
//|  plus the TRANSFER-STATE ladder (Stable -> Building -> Contested |
//|  -> Transferring -> Complete), the Wyckoff FOUR-SHIFT count at   |
//|  terminal/transition zones (spring/test/LPS1/LPS2 = always 4),   |
//|  and the ENTRY ARCHITECTURE (wide large-recursion vs compressed  |
//|  failure-swing) that decides how the entry cycle will build.     |
//|                                                                  |
//|  Context + management read only; never gates the Letra trigger.  |
//+------------------------------------------------------------------+

//================= OWNERSHIP MAP OUTPUTS ==========================
double mo_pct[6];                 // ownership % per rung (M1,M3,M5,M15,H1,H4)
string mo_lbl[6];                 // rung labels
int    mo_dirArr[6];              // rung directions
int    mo_ownerIdx=2, mo_secondIdx=4;
double mo_ownerPct=0.0, mo_secondPct=0.0;
string mo_ownerLabel="M5", mo_secondLabel="H1";
int    mo_dir=0;                  // owning rung direction
string mo_transferState="STABLE"; // STABLE|BUILDING|CONTESTED|TRANSFERRING|COMPLETE
int    mo_wyckoffShifts=0;        // shifts toward the canonical 4
bool   mo_fourShiftDone=false;
string mo_entryArch="MIXED";      // WIDE | COMPRESSION | MIXED
int    mo_expectedEntries=1;

void MtfOwnership_Init() {}

//--- rung label from the adaptive ladder
string MO_TFLabel(const ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1:  return "M1";   case PERIOD_M3:  return "M3";  case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";  case PERIOD_M30: return "M30"; case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";   case PERIOD_D1:  return "D1";  case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";   default: return EnumToString(tf);
     }
  }

void MtfOwnership_Compute()
  {
   //--- per-rung curve state (each timeframe's own recursive curve)
   mo_dirArr[0]=m1_dir; mo_dirArr[1]=l3_dir; mo_dirArr[2]=l0_dir;
   mo_dirArr[3]=l1_dir; mo_dirArr[4]=l2_dir; mo_dirArr[5]=l4_dir;
   double wp[6];   wp[0]=se1_wp;  wp[1]=se3_wp;  wp[2]=se5_wp;  wp[3]=se15_wp;  wp[4]=se60_wp;  wp[5]=se240_wp;
   double dom[6];  dom[0]=se1_dom;dom[1]=se3_dom;dom[2]=se5_dom;dom[3]=se15_dom;dom[4]=se60_dom;dom[5]=se240_dom;
   //--- contextual timeframe authority (higher TF carries more weight)
   double tfW[6];  tfW[0]=0.04; tfW[1]=0.06; tfW[2]=0.14; tfW[3]=0.20; tfW[4]=0.26; tfW[5]=0.30;

   mo_lbl[0]=MO_TFLabel(g_ladderTF[0]); mo_lbl[1]=MO_TFLabel(g_ladderTF[1]); mo_lbl[2]=MO_TFLabel(g_ladderTF[2]);
   mo_lbl[3]=MO_TFLabel(g_ladderTF[3]); mo_lbl[4]=MO_TFLabel(g_ladderTF[4]); mo_lbl[5]=MO_TFLabel(g_ladderTF[5]);

   //--- ownership weight: a curve owns price when it is mid-progress (actively
   //    delivering) and carries dominance/recursion energy, scaled by TF authority.
   double raw[6]; double tot=0.0;
   for(int i=0;i<6;i++)
     {
      double midW = MathMax(0.0, 1.0 - MathAbs(wp[i]-50.0)/55.0);   // peaks at mid-progress
      raw[i] = tfW[i] * (0.5 + 0.5*midW) * (1.0 + dom[i]/200.0);
      tot += raw[i];
     }
   mo_ownerIdx=0; mo_secondIdx=1; mo_ownerPct=0.0; mo_secondPct=0.0;
   for(int i=0;i<6;i++)
     {
      mo_pct[i] = tot>0.0 ? raw[i]/tot*100.0 : 0.0;
      if(mo_pct[i]>mo_ownerPct){ mo_secondPct=mo_ownerPct; mo_secondIdx=mo_ownerIdx; mo_ownerPct=mo_pct[i]; mo_ownerIdx=i; }
      else if(mo_pct[i]>mo_secondPct){ mo_secondPct=mo_pct[i]; mo_secondIdx=i; }
     }
   mo_ownerLabel=mo_lbl[mo_ownerIdx];
   mo_secondLabel=mo_lbl[mo_secondIdx];
   mo_dir = mo_dirArr[mo_ownerIdx];

   //--- transfer-state ladder (dominance within the owning curve + contest gap)
   double domOwner = dom[mo_ownerIdx];
   double gap = mo_ownerPct - mo_secondPct;
   mo_transferState =
        domOwner>=70.0 ? "COMPLETE" :
        domOwner>=50.0 ? "TRANSFERRING" :
        gap<12.0       ? "CONTESTED" :
        domOwner>=40.0 ? "BUILDING" : "STABLE";

   //--- Wyckoff four-shift (only meaningful at terminal/transition zones)
   bool terminal = (co_campaign=="TERMINAL");
   mo_wyckoffShifts = terminal ? (int)MathMin(4.0, se5_rec) : 0;
   mo_fourShiftDone = terminal && (se5_rec>=4.0 || co_transferComplete);

   //--- entry architecture from terminal compression (Model A wide vs Model B tight)
   double comp = se5_comp;
   mo_entryArch = comp>=60.0 ? "COMPRESSION (failure-swing + tiny recursions)" :
                  comp<25.0  ? "WIDE (large recursions)" : "MIXED";
   mo_expectedEntries = comp>=75.0 ? 4 : comp>=50.0 ? 3 : comp>=25.0 ? 2 : 1;
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/CurveLife.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  CurveLife.mqh - F72 "is the trade alive?" engine                |
//|                                                                  |
//|  Instead of asking how deep a move retraces, it asks whether the |
//|  COUNTER side can even build a move here. It scores the live      |
//|  campaign as ALIVE (hold) / WEAKENING (manage) / DEAD (flip), and |
//|  adds:                                                           |
//|   - Compression persistence / ownership migration: when the      |
//|     losing side can't generate room, support/resistance migrates |
//|     to the 0.5-0.618 band of the expansion leg.                  |
//|   - Narrative lineage / chain vitality: are successive pullbacks |
//|     getting shallower (story strengthening) or deeper (fading).  |
//|                                                                  |
//|  The owning curve is the canonical M5 wave (se5); recursion depth |
//|  comes from the structure engine's recursive-transition count    |
//|  (se5_rec) and the compression index (se5_comp). Outputs are     |
//|  consumed by the trade manager to manage OPEN trades only - they  |
//|  never gate the Letra entries.                                   |
//+------------------------------------------------------------------+

//================= CURVE-LIFE OUTPUTS =============================
double cl_life=50.0;
string cl_state="WEAKENING";       // ALIVE | WEAKENING | DEAD
int    cl_ownDir=0;                // owning curve direction
int    cl_counterDir=0;            // flip direction when DEAD
string cl_aliveTx="—";
string cl_cpState="NEUTRAL";       // PERSISTING | NEUTRAL | LEAKING
string cl_cpTrend="-> stable";
double cl_cpForce=0.0;
string cl_narrState="HOLDING";     // STRENGTHENING | HOLDING | WEAKENING
double cl_narrative=50.0;
double cl_chainVitality=50.0, cl_wholeChainLife=50.0;
string cl_chainScope="healthy";
double cl_mig50=PINE_NA, cl_mig618=PINE_NA;
double cl_parentThreat=PINE_NA, cl_htfRoomAtr=PINE_NA;
string cl_htfThreat="—";
bool   cl_progressing=false;

//--- internal persistent state
CRing  g_compHist;
int    g_narrDir=0;
double g_legX=PINE_NA, g_legPBdepth=0.0;
int    g_supVotes=0, g_degVotes=0;
double g_seqRetr[];
double g_lifeSeq[];

void CurveLife_Init()
  {
   g_compHist.Init(16);
   g_narrDir=0; g_legX=PINE_NA; g_legPBdepth=0.0;
   g_supVotes=0; g_degVotes=0;
   cl_narrative=50.0; cl_wholeChainLife=50.0;
   ArrayResize(g_seqRetr,0); ArrayResize(g_lifeSeq,0);
  }

void CL_PushCap(double &arr[],const double v,const int cap)
  {
   int n=ArraySize(arr); ArrayResize(arr,n+1); arr[n]=v;
   while(ArraySize(arr)>cap) ArrayRemove(arr,0,1);
  }

void CurveLife_Compute()
  {
   double cl=C_close(), hi=C_high(), lo=C_low();
   double atrv=IsNa(atr)?0.0:atr;

   //--- owner curve = the curve-tree owner (authoritative), fallback to canonical M5
   int    ownDir = ct_ownDir!=0 ? ct_ownDir : l0_dir;
   double ownOrig= !IsNa(ct_ownOrig) ? ct_ownOrig : se5_inv;
   double ownExt = !IsNa(ct_ownExt) ? ct_ownExt : ((ownDir==1) ? se5_sh : (ownDir==-1) ? se5_sl : PINE_NA);
   cl_ownDir = ownDir;
   cl_counterDir = -ownDir;

   //--- compression persistence (read FROM the canonical compression)
   double cmpNow = se5_comp;
   g_compHist.Push(cmpNow);
   double cmp5 = g_compHist.Has(5) ? g_compHist.Get(5) : cmpNow;
   double cmpTighten = cmpNow - cmp5;
   double eRes = re_residualEnergyScore;
   int    treeDepth = ct_treeDepth;
   int    budget = co_expectedDepth;   // geometry-aware curve budget (Principle 4)
   bool   recComplete = (budget>0 && treeDepth>=budget);

   cl_cpForce = Clamp(cmpNow*0.50 + eRes*0.20 - treeDepth*12.0 + MathMax(0.0,cmpTighten)*0.8 + 8.0, 0.0, 100.0);
   cl_cpState = cl_cpForce>=60.0 ? "PERSISTING" : cl_cpForce<=35.0 ? "LEAKING" : "NEUTRAL";
   cl_cpTrend = cmpTighten>3.0 ? "tightening" : cmpTighten<-3.0 ? "broadening" : "stable";

   //--- progress guard: attacking the extreme / trend impulse = strength
   bool attacking = ownDir==1 ? (hi>=Nz(ownExt,hi)) : ownDir==-1 ? (lo<=Nz(ownExt,lo)) : false;
   bool trendImp  = (ownDir==1 && bullImpulse)||(ownDir==-1 && bearImpulse);
   cl_progressing = attacking||trendImp;

   //--- retrace depth from the curve's extreme
   double retrX = (IsNa(ownExt)||IsNa(ownOrig)||ownExt==ownOrig) ? 50.0 :
                  PineMin(MathAbs(ownExt-cl)/MathMax(MathAbs(ownExt-ownOrig),1e-10)*100.0, 100.0);

   //--- HTF parent threat (H4 zone)
   cl_parentThreat = ownDir==1 ? ((!IsNa(se240_ft)&&se240_ft>cl)?se240_ft:se240_sh) :
                     ownDir==-1 ? ((!IsNa(se240_fb)&&se240_fb<cl)?se240_fb:se240_sl) : PINE_NA;
   cl_htfRoomAtr = IsNa(cl_parentThreat) ? PINE_NA : MathAbs(cl_parentThreat-cl)/MathMax(atrv,1e-10);
   cl_htfThreat = IsNa(cl_htfRoomAtr) ? "—" : cl_htfRoomAtr>3.0 ? "CLEAR runway" : cl_htfRoomAtr>1.0 ? "APPROACHING" : "AT ZONE";

   //--- LIFE score
   cl_life = Clamp(
        cl_cpForce*0.45 + eRes*0.30 +
        (cmpTighten>0.0 ? 12.0 : 0.0) -
        ((recComplete && !cl_progressing) ? 25.0 : 0.0) -
        ((cl_cpState=="LEAKING" && !cl_progressing) ? 20.0 : 0.0) +
        (cl_progressing ? 28.0 : 0.0) +
        (retrX<25.0 ? 16.0 : retrX<45.0 ? 6.0 : retrX>75.0 ? -12.0 : 0.0) + 10.0, 0.0, 100.0);

   //--- ALIVE / WEAKENING / DEAD verdict
   if(ownDir==0)                                   { cl_state="WEAKENING"; cl_aliveTx="no curve - wait"; }
   else if(cl_htfThreat=="AT ZONE" && cl_life>=45) { cl_state="ALIVE"; cl_aliveTx="ALIVE - AT H4, VIGILANT"; }
   else if(cl_progressing && cl_life>=45)          { cl_state="ALIVE"; cl_aliveTx="ALIVE - ATTACKING EXTREME"; }
   else if(cl_life>=60.0)                          { cl_state="ALIVE"; cl_aliveTx="ALIVE - HOLD"; }
   else if(cl_life<=32.0)                          { cl_state="DEAD";  cl_aliveTx=(ownDir==1?"DEAD - FLIP SHORT":"DEAD - FLIP LONG"); }
   else                                            { cl_state="WEAKENING"; cl_aliveTx="WEAKENING - MANAGE"; }

   //--- FU-merge / ownership transfer override (Principle 9)
   if(ct_transferred)
     { cl_life=MathMin(cl_life,30.0); cl_state="DEAD"; cl_aliveTx="DEAD - OWNERSHIP TRANSFERRED ("+ct_ownStateTx+")"; }
   else if(ct_merged && cl_state=="DEAD")
     { cl_life=MathMax(cl_life,50.0); cl_state="WEAKENING"; cl_aliveTx="HOLD - child MERGED back to parent"; }

   //--- cross-TF ownership transfer: if the MTF owner has fully flipped against
   //    the curve owner, higher-order control has moved -> bias toward DEAD/flip
   if(mo_transferState=="COMPLETE" && mo_dir!=0 && mo_dir!=cl_ownDir)
     { cl_life=MathMin(cl_life,35.0); if(cl_life<=32.0){ cl_state="DEAD"; cl_aliveTx="DEAD - MTF ownership flipped ("+mo_ownerLabel+")"; } }

   //--- migrated ownership band (0.5 / 0.618 of the owner leg)
   cl_mig50  = (IsNa(ownOrig)||IsNa(ownExt)) ? PINE_NA : ownExt + 0.5  *(ownOrig-ownExt);
   cl_mig618 = (IsNa(ownOrig)||IsNa(ownExt)) ? PINE_NA : ownExt + 0.618*(ownOrig-ownExt);

   //--- NARRATIVE LINEAGE - successive pullback depths
   if(ownDir!=g_narrDir)
     {
      g_narrDir=ownDir;
      g_legX = ownDir==1?hi:ownDir==-1?lo:PINE_NA;
      g_legPBdepth=0.0; cl_narrative=50.0; g_supVotes=0; g_degVotes=0;
      ArrayResize(g_seqRetr,0); ArrayResize(g_lifeSeq,0);
     }
   if(ownDir!=0 && !IsNa(ownOrig))
     {
      bool newLegX = ownDir==1 ? hi>Nz(g_legX,hi) : lo<Nz(g_legX,lo);
      if(newLegX)
        {
         if(g_legPBdepth>6.0)
           {
            bool sup = g_legPBdepth<=50.0 && cmpTighten>=-1.0;
            bool deg = g_legPBdepth>=62.0 || cmpTighten<-3.0;
            int  vote = sup?1:deg?-1:0;
            g_supVotes += (vote==1?1:0);
            g_degVotes += (vote==-1?1:0);
            cl_narrative = Clamp(cl_narrative + vote*12.0 + (cmpTighten>0.0?3.0:-3.0), 0.0, 100.0);
            CL_PushCap(g_seqRetr, g_legPBdepth, 5);
            CL_PushCap(g_lifeSeq, cl_life, 5);
           }
         g_legX = ownDir==1?hi:lo;
         g_legPBdepth=0.0;
        }
      else
        {
         double pbd = MathAbs(Nz(g_legX,cl)-ownOrig)>1e-9 ? MathAbs(Nz(g_legX,cl)-cl)/MathAbs(Nz(g_legX,cl)-ownOrig)*100.0 : 0.0;
         g_legPBdepth = MathMax(g_legPBdepth, pbd);
        }
     }
   cl_narrState = cl_narrative>=65.0 ? "STRENGTHENING" : cl_narrative<=35.0 ? "WEAKENING" : "HOLDING";

   //--- CHAIN VITALITY (is life decaying across successive curves?)
   cl_wholeChainLife = cl_wholeChainLife + 0.02*(cl_life-cl_wholeChainLife);
   int ls=ArraySize(g_lifeSeq);
   cl_chainVitality = ls>=2 ? Clamp(50.0+(g_lifeSeq[ls-1]-g_lifeSeq[0]), 0.0, 100.0) : cl_wholeChainLife;
   cl_chainScope = cl_life>=50.0 ? "healthy" :
                   cl_chainVitality>=50.0 ? "CURVE only - chain intact" :
                   cl_wholeChainLife>=45.0 ? "CHAIN weakening" : "WHOLE CHAIN decaying";
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/TradeManager.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  TradeManager.mqh - execution + risk management                  |
//|                                                                  |
//|  Consumes the engine signals (sig_longSignal / sig_shortSignal / |
//|  sig_exitNow / sig_tradeDir) and runs autonomous order           |
//|  management with hedge-fund-grade controls:                      |
//|    * risk-% position sizing from the stop distance               |
//|    * structural (flip-zone / invalidation) or ATR stops          |
//|    * ATR take-profit, ATR trailing stop, breakeven               |
//|    * spread filter, session filter, max-positions cap            |
//|    * daily-loss limit and total-drawdown circuit breaker         |
//+------------------------------------------------------------------+

CTrade g_trade;

//--- cached symbol info
double tm_point=0, tm_tickSize=0, tm_tickValue=0, tm_volMin=0, tm_volMax=0, tm_volStep=0;
int    tm_digits=0; long tm_stopLevel=0;

//--- risk-state tracking
double tm_peakEquity=0;
double tm_dayStartEquity=0;
int    tm_dayStamp=-1;
bool   tm_halted=false;

//==================================================================
void Trade_Init()
  {
   tm_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   tm_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   tm_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   tm_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   tm_volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   tm_volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   tm_volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   tm_stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(tm_tickSize<=0) tm_tickSize=tm_point;
   tm_peakEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   tm_dayStartEquity = tm_peakEquity;
   tm_dayStamp       = -1;
   tm_halted         = false;
  }

//==================================================================
//  Helpers
//==================================================================
int Trade_CountPositions()
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      n++;
     }
   return n;
  }

//--- net direction of EA positions (+1 long, -1 short, 0 none/mixed)
int Trade_NetDir()
  {
   int dir=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      int pd=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
      if(dir==0) dir=pd; else if(dir!=pd) return 0;
     }
   return dir;
  }

void Trade_CloseAll(const string why)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      g_trade.PositionClose(tk);
     }
  }

double Trade_NormalizeLots(double lots)
  {
   if(tm_volStep>0) lots = MathFloor(lots/tm_volStep)*tm_volStep;
   lots = MathMax(tm_volMin, MathMin(tm_volMax, lots));
   //--- round to step decimals
   int dec=0; double s=tm_volStep;
   while(s<1.0 && dec<8){ s*=10.0; dec++; }
   return NormalizeDouble(lots, dec);
  }

//--- lot size from risk% and stop distance (price units)
double Trade_LotsForRisk(const double stopDistPrice)
  {
   if(InpFixedLots>0.0) return Trade_NormalizeLots(InpFixedLots);
   if(stopDistPrice<=0 || tm_tickSize<=0 || tm_tickValue<=0) return tm_volMin;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity*InpRiskPercent/100.0;
   double ticks = stopDistPrice/tm_tickSize;
   double lossPerLot = ticks*tm_tickValue;
   if(lossPerLot<=0) return tm_volMin;
   double lots = riskMoney/lossPerLot;
   return Trade_NormalizeLots(lots);
  }

//--- session / day filters
bool Trade_SessionOK()
  {
   if(!InpUseSession) return true;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(!InpTradeMonday && t.day_of_week==1) return false;
   if(!InpTradeFriday && t.day_of_week==5) return false;
   if(t.day_of_week==0 || t.day_of_week==6) return false;
   int h=t.hour;
   if(InpSessionStartHr<=InpSessionEndHr)
      return(h>=InpSessionStartHr && h<InpSessionEndHr);
   else
      return(h>=InpSessionStartHr || h<InpSessionEndHr); // wraps midnight
  }

bool Trade_SpreadOK()
  {
   if(InpMaxSpreadPoints<=0) return true;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sp=(ask-bid)/MathMax(tm_point,1e-10);
   return(sp<=InpMaxSpreadPoints);
  }

//--- risk circuit breakers (daily loss + total drawdown)
void Trade_UpdateRiskState()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity>tm_peakEquity) tm_peakEquity=equity;

   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   int stamp = t.year*1000+t.day_of_year;
   if(stamp!=tm_dayStamp){ tm_dayStamp=stamp; tm_dayStartEquity=equity; }

   tm_halted=false;
   if(InpMaxDailyLossPct>0.0)
     {
      double dd = (tm_dayStartEquity-equity)/MathMax(tm_dayStartEquity,1e-10)*100.0;
      if(dd>=InpMaxDailyLossPct) tm_halted=true;
     }
   if(InpMaxTotalDDPct>0.0)
     {
      double tdd = (tm_peakEquity-equity)/MathMax(tm_peakEquity,1e-10)*100.0;
      if(tdd>=InpMaxTotalDDPct) tm_halted=true;
     }
  }

//==================================================================
//  Entry & exit on each new work bar
//==================================================================
void Trade_OnSignals()
  {
   if(!InpEnableTrading) return;
   Trade_UpdateRiskState();

   //--- engine EXIT
   if(sig_exitNow && Trade_CountPositions()>0)
     {
      Trade_CloseAll("engine exit");
      return;
     }
   //--- close on direction flip if requested
   if(InpCloseOnExit)
     {
      int nd=Trade_NetDir();
      if(nd==1 && sig_shortSignal) Trade_CloseAll("flip to short");
      if(nd==-1 && sig_longSignal) Trade_CloseAll("flip to long");
     }

   //--- F72 curve-life management (DEAD exits / WEAKENING breakeven)
   Trade_ManageCurveLife();

   if(tm_halted) return;                 // risk circuit breaker
   if(!Trade_SessionOK()) return;
   if(!Trade_SpreadOK())  return;

   bool wantLong  = sig_longSignal;
   bool wantShort = sig_shortSignal;
   if(!wantLong && !wantShort) return;

   //--- respect position cap & avoid stacking same dir
   int nd=Trade_NetDir();
   if(Trade_CountPositions()>=InpMaxPositions) return;
   if(wantLong  && nd==1)  return;       // already long
   if(wantShort && nd==-1) return;       // already short

   double atrv = IsNa(atr) ? 0.0 : atr;
   if(atrv<=0) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double minStop = (double)tm_stopLevel*tm_point;

   if(wantLong)
     {
      double entry = ask;
      double sl;
      if(InpUseStructSL && !IsNa(flipBot))
         sl = MathMin(flipBot, !IsNa(l0_inv)?l0_inv:flipBot) - atrv*0.25;
      else
         sl = entry - atrv*InpSL_ATR;
      if(entry-sl < minStop) sl = entry-minStop-tm_point;
      double tp = (InpTP_ATR>0.0) ? entry + atrv*InpTP_ATR : 0.0;
      double lots = Trade_LotsForRisk(entry-sl);
      sl=NormalizeDouble(sl,tm_digits); if(tp>0) tp=NormalizeDouble(tp,tm_digits);
      if(!g_trade.Buy(lots,_Symbol,0.0,sl,tp,InpTradeComment))
         PrintFormat("Letra37 BUY failed: %d %s",g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      else
         PrintFormat("Letra37 BUY %.2f lots sl=%.5f tp=%.5f grade=%s prob=%.0f",lots,sl,tp,sig_grade,sig_finalProb);
     }
   else if(wantShort)
     {
      double entry = bid;
      double sl;
      if(InpUseStructSL && !IsNa(flipTop))
         sl = MathMax(flipTop, !IsNa(l0_inv)?l0_inv:flipTop) + atrv*0.25;
      else
         sl = entry + atrv*InpSL_ATR;
      if(sl-entry < minStop) sl = entry+minStop+tm_point;
      double tp = (InpTP_ATR>0.0) ? entry - atrv*InpTP_ATR : 0.0;
      double lots = Trade_LotsForRisk(sl-entry);
      sl=NormalizeDouble(sl,tm_digits); if(tp>0) tp=NormalizeDouble(tp,tm_digits);
      if(!g_trade.Sell(lots,_Symbol,0.0,sl,tp,InpTradeComment))
         PrintFormat("Letra37 SELL failed: %d %s",g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      else
         PrintFormat("Letra37 SELL %.2f lots sl=%.5f tp=%.5f grade=%s prob=%.0f",lots,sl,tp,sig_grade,sig_finalProb);
     }
  }

//==================================================================
//  F72 curve-life management of OPEN trades (per closed work bar).
//  Manage-only: never opens or gates entries.
//    DEAD (owning curve died) -> abandon a with-owner position
//    WEAKENING                -> move SL to breakeven if in profit
//==================================================================
void Trade_ManageCurveLife()
  {
   if(!InpEnableTrading || !InpUseCurveLife) return;
   int nd=Trade_NetDir();
   if(nd==0) return;

   //--- owning curve is DEAD and we hold a position aligned with it -> exit
   if(InpCurveLifeFlatOnDead && cl_state=="DEAD" && nd==cl_ownDir)
     {
      Trade_CloseAll("curve-life DEAD");
      return;
     }

   //--- WEAKENING -> lock breakeven on any position that is in profit
   if(InpCurveLifeTightenWeak && cl_state=="WEAKENING")
     {
      double point=tm_point;
      double minStop=(double)tm_stopLevel*point;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
         int    ptype=(int)PositionGetInteger(POSITION_TYPE);
         double open =PositionGetDouble(POSITION_PRICE_OPEN);
         double curSL=PositionGetDouble(POSITION_SL);
         double curTP=PositionGetDouble(POSITION_TP);
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         if(ptype==POSITION_TYPE_BUY)
           {
            double be=open+point*2;
            if(bid-open>0 && (curSL<be) && (bid-be)>=minStop)
               g_trade.PositionModify(tk, NormalizeDouble(be,tm_digits), curTP);
           }
         else if(ptype==POSITION_TYPE_SELL)
           {
            double be=open-point*2;
            if(open-ask>0 && (curSL>be || curSL==0.0) && (be-ask)>=minStop)
               g_trade.PositionModify(tk, NormalizeDouble(be,tm_digits), curTP);
           }
        }
     }
  }

//==================================================================
//  Intrabar management: trailing stop + breakeven (every tick)
//==================================================================
void Trade_ManageOpen()
  {
   if(!InpEnableTrading) return;
   if(!InpUseTrailing && !InpUseBreakeven) return;
   double atrv = IsNa(atr) ? 0.0 : atr;
   if(atrv<=0) return;

   double point=tm_point;
   double minStop=(double)tm_stopLevel*point;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      int    ptype = (int)PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double newSL = curSL;

      if(ptype==POSITION_TYPE_BUY)
        {
         double profit = bid-open;
         //--- breakeven
         if(InpUseBreakeven && profit>=atrv*InpBE_ATR)
           {
            double be=open+point*2;
            if(curSL<be) newSL=MathMax(newSL,be);
           }
         //--- trailing
         if(InpUseTrailing && profit>=atrv*InpTrailStartATR)
           {
            double trail=bid-atrv*InpTrailATR;
            if(trail>newSL) newSL=trail;
           }
         if(newSL>curSL && (bid-newSL)>=minStop)
            g_trade.PositionModify(tk, NormalizeDouble(newSL,tm_digits), curTP);
        }
      else if(ptype==POSITION_TYPE_SELL)
        {
         double profit = open-ask;
         if(InpUseBreakeven && profit>=atrv*InpBE_ATR)
           {
            double be=open-point*2;
            if(curSL>be || curSL==0.0) newSL=(curSL==0.0)?be:MathMin(newSL,be);
           }
         if(InpUseTrailing && profit>=atrv*InpTrailStartATR)
           {
            double trail=ask+atrv*InpTrailATR;
            if(trail<newSL || curSL==0.0) newSL=(curSL==0.0)?trail:MathMin(newSL,trail);
           }
         if(newSL!=curSL && newSL>0 && (newSL-ask)>=minStop)
            g_trade.PositionModify(tk, NormalizeDouble(newSL,tm_digits), curTP);
        }
     }
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/Dashboard.mqh
// =================================================================
//+------------------------------------------------------------------+
//|  Dashboard.mqh - on-chart status panel                           |
//|                                                                  |
//|  Renders the engine's live state via Comment() (reliable         |
//|  multi-line). Mirrors the decision-relevant readouts of the      |
//|  original dashboards.                                            |
//+------------------------------------------------------------------+

string DirWord(const int d){ return d==1?"BULL":d==-1?"BEAR":"FLAT"; }

void Dash_Destroy()
  {
   Comment("");
  }

void Dash_Update()
  {
   if(!InpShowDashboard) return;

   string nl="\n";
   string s="";
   s += "===== LETRA 37  ("+_Symbol+"  "+EnumToString(InpWorkTF)+") =====" + nl;
   s += "Directive : " + sig_directive + nl;
   s += "Phase     : " + ie1a_currentPhase + "  ["+DirWord(direction)+"]  conf "+DoubleToString(ie1a_phaseConfidence,0)+"%" + nl;
   s += "Grade     : " + grade + "   ContProb "+DoubleToString(contProb,0)+"%   FinalProb "+DoubleToString(finalProb,0)+"%" + nl;
   s += "NetEdge   : " + DoubleToString(netEdgeAdjusted,1) + "   ("+liveDirective+")" + nl;
   s += "Beliefs   : DR "+DoubleToString(d_demandReturnBelief,0)+"  Exp "+DoubleToString(d_expansionBelief,0)+"  Abs "+DoubleToString(d_absorptionBelief,0)+"  Conv "+DoubleToString(d_convexityBelief,0) + nl;
   s += "WaveProg  : " + DoubleToString(waveProgress,0)+"%   ModelFit "+DoubleToString(waveModelFit,0)+"%   ModelConf "+DoubleToString(modelConfidence,0)+"%" + nl;
   s += "FractStack: " + DirWord(fractalStackDir)+"  "+DoubleToString(fractalStackScore,0)+"%   (M1 "+DirWord(m1_dir)+" L0 "+DirWord(l0_dir)+" L2 "+DirWord(l2_dir)+" L4 "+DirWord(l4_dir)+")" + nl;
   s += "HTF Bias  : tf1 "+DirWord(htfBias1)+"  tf2 "+DirWord(htfBias2)+"  align "+DirWord(htfAlign) + nl;
   s += "Liquidity : Heat "+DoubleToString(liqHeat,0)+"  "+liqZone+"   sweepOK "+(liqSweepOK?"Y":"N") + nl;
   s += "ERF       : "+re_resolutionState+"  ready "+DoubleToString(erf_tradeReadiness,0)+"%  gate "+(erf_entryGate?"OPEN":"SHUT") + nl;
   s += "FlipStages: " + IntegerToString(flipzoneStagesComplete)+"/5   obFresh "+(obFresh?"Y":"N") + nl;
   s += "CurveLife : " + cl_aliveTx + "  (life "+DoubleToString(cl_life,0)+")" + nl;
   s += "  force   : " + cl_cpState+" "+cl_cpTrend+"   narr "+cl_narrState+"   chain "+cl_chainScope + nl;
   s += "  HTF     : " + cl_htfThreat+(IsNa(cl_htfRoomAtr)?"":"  "+DoubleToString(cl_htfRoomAtr,1)+" ATR") + nl;
   s += "Ownership : "+co_buildingVsEntry+"  ["+co_entryReadiness+"]   owner "+co_ownerLabel + nl;
   s += "  campaign: "+co_campaign+" / "+co_location+"   "+co_compRegime + nl;
   s += "  recurse : depth "+IntegerToString(co_recDepth)+"/"+IntegerToString(co_expectedDepth)+"   dom old "+DoubleToString(co_oldPct,0)+"/new "+DoubleToString(co_newPct,0)+(co_transferComplete?" XFER":"")+"   budget "+DoubleToString(co_remainingBudget,0)+"%" + nl;
   s += "  particip: "+co_partZone + nl;
   s += "CurveTree : owner "+DirWord(ct_ownDir)+" d"+IntegerToString(ct_ownDepth)+" e"+DoubleToString(ct_ownEnergy,0)+"  "+ct_ownState + nl;
   s += "  nodes   : "+IntegerToString(ct_treeAlive)+" alive  depth "+IntegerToString(ct_treeDepth)+"/"+IntegerToString(ct_budgetDepth)+"   "+ct_ownStateTx + nl;
   s += "MTF own   : "+mo_ownerLabel+" "+DoubleToString(mo_ownerPct,0)+"% / "+mo_secondLabel+" "+DoubleToString(mo_secondPct,0)+"%  "+DirWord(mo_dir)+"  ["+mo_transferState+"]" + nl;
   s += "  arch    : "+mo_entryArch+"  ~"+IntegerToString(mo_expectedEntries)+" entries   Wyckoff "+IntegerToString(mo_wyckoffShifts)+"/4" + nl;
   s += "TimeIntel : dir "+DirWord(timeDir)+"  align "+DoubleToString(timeAlign,0)+"%   H1 "+h1Timing+" ("+tH1State+")" + nl;
   s += "TradeState: " + (tradeDir==1?"LONG":tradeDir==-1?"SHORT":"FLAT") + "   positions "+IntegerToString(Trade_CountPositions()) + nl;
   s += "Vol regime: " + phys_volRegime + "  ATR "+DoubleToString(IsNa(atr)?0.0:atr,_Digits);

   Comment(s);
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Include/Letra37/Pipeline.mqh
// =================================================================
//+------------------------------------------------------------------+
//|                                                 Pipeline.mqh     |
//|     Master orchestration: warm-up + per-bar evaluation.          |
//|     Included LAST so every engine function is already declared.  |
//|                                                                  |
//|     The per-bar order reproduces the original Pine script's      |
//|     top-to-bottom evaluation:                                    |
//|       fixed-TF structure & physics & HTF beliefs (security)      |
//|        -> push current chart bar                                 |
//|        -> live direction / Engine 1A                             |
//|        -> Sec 4-8 market structure / wave context                |
//|        -> Sec 9 observation scores                               |
//|        -> ERF (uses prev-bar forward vars, current obs)          |
//|        -> Sec 10 liquidity heatmap                               |
//|        -> Sec 11-12 geometry + wave intelligence (beliefs)       |
//|        -> Sec 13-14 wave spawn + induction classification        |
//|        -> Sec 15-24 scoring/Bayesian/opportunity/signals/state   |
//+------------------------------------------------------------------+

//==================================================================
//  Evaluate one CLOSED work-TF bar identified by its OPEN time.
//==================================================================
void Ctx_StepWorkBar(const datetime workOpenTime)
  {
   int wper = PeriodSeconds(cfg_workTF);
   datetime moment = (datetime)(workOpenTime + wper); // bar close moment

   //--- 1) advance per-timeframe engines up to this close moment
   Struct_FeedAll(moment);
   Phys_Feed(moment);
   Belief_Feed(moment);

   //--- 2) push the just-closed work bar into chart-context rings
   int sh = iBarShift(_Symbol, cfg_workTF, workOpenTime, true);
   if(sh<0) sh = 1;
   double o = iOpen (_Symbol, cfg_workTF, sh);
   double h = iHigh (_Symbol, cfg_workTF, sh);
   double l = iLow  (_Symbol, cfg_workTF, sh);
   double c = iClose(_Symbol, cfg_workTF, sh);
   double v = (double)iVolume(_Symbol, cfg_workTF, sh);
   if(o==0 && h==0 && l==0 && c==0) return; // no data
   Ctx_PushWorkBar(o,h,l,c,v);

   //--- 3) live direction derivation + Engine 1A (depends on chart close)
   Struct_DeriveLive();
   Belief_DeriveLive();

   //--- 4) chart-context engines, in source order
   MS_Compute();        // Sec 4-8
   Obs_Compute();       // Sec 9
   Erf_Compute();       // ERF
   Liq_Compute();       // Sec 10
   GeoWave_Compute();   // Sec 11-12
   WaveSpawn_Compute(); // Sec 13-14
   Signals_Compute();   // Sec 15-24
   TimeIntel_Compute(); // Time Intelligence Engine (context)
   CurveTree_Compute(); // F72 literal recursive curve tree (per-node ownership/merge)
   CurveOwnership_Compute(); // F72 recursive curve ownership (budget/building-vs-entry)
   MtfOwnership_Compute();   // cross-TF curve-ownership map + transfer-state ladder
   CurveLife_Compute(); // F72 curve-life (open-trade management)
  }

//==================================================================
//  Live: called when a brand-new work bar has closed.
//==================================================================
void Ctx_OnNewWorkBar()
  {
   //--- the just-closed bar is shift 1 (shift 0 is forming)
   datetime openT = iTime(_Symbol, cfg_workTF, 1);
   if(openT==0) return;
   Ctx_StepWorkBar(openT);
  }

//==================================================================
//  Warm-up: replay history so all stateful engines hold valid
//  state before the EA starts trading live.
//==================================================================
void Ctx_WarmUp()
  {
   int avail = Bars(_Symbol, cfg_workTF);
   if(avail<50){ Print("Letra37: not enough work-TF history (",avail," bars)"); return; }

   //--- replay up to this many closed work bars (cap to ring capacity)
   int warm = (int)MathMin(avail-2, CTX_RING_CAP-4);
   if(warm<50) warm = (int)MathMin(avail-2, 50);

   //--- iterate from oldest (shift=warm) down to the last closed bar (shift=1)
   for(int s=warm; s>=1; s--)
     {
      datetime openT = iTime(_Symbol, cfg_workTF, s);
      if(openT==0) continue;
      Ctx_StepWorkBar(openT);
     }

   if(g_barIndex>=0)
      g_lastWorkBarTime = iTime(_Symbol, cfg_workTF, 0);

   Print("Letra37: warm-up complete over ",warm," work-TF bars. barIndex=",g_barIndex);
  }
//+------------------------------------------------------------------+

// =================================================================
// ==== INLINED: Letra37EA.mq5 (lifecycle: OnInit/OnDeinit/OnTick)
// =================================================================
int OnInit()
  {
   //--- bind config from inputs into the shared context
   Ctx_LoadInputs();
   SharedState_Init();

   //--- configure trade object
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   //--- initialise engine state
   Phys_Init();
   Struct_InitAll();
   Belief_Init();
   MS_Init();
   ObsLiq_Init();
   GeoWave_Init();
   WaveSpawn_Init();
   Erf_Init();
   Signals_Init();
   TimeIntel_Init();
   CurveTree_Init();
   CurveOwnership_Init();
   MtfOwnership_Init();
   CurveLife_Init();
   Trade_Init();

   //--- warm up the engines on history so live decisions are valid
   Ctx_WarmUp();

   Print("Letra37 EA initialised. WorkTF=",EnumToString(InpWorkTF),
         "  tf1=",EnumToString(InpTf1),"  tf2=",EnumToString(InpTf2));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Dash_Destroy();
   Comment("");
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- intrabar management (trailing / breakeven / safety) runs every tick
   Trade_ManageOpen();

   //--- the engine evaluates only on a CLOSED work-TF bar (like Pine bar close)
   datetime t = iTime(_Symbol, InpWorkTF, 0);
   if(t==0) return;
   if(t==g_lastWorkBarTime) return;     // no new work-TF bar yet
   g_lastWorkBarTime = t;

   //--- a new work-TF bar just closed -> advance the full pipeline one step
   Ctx_OnNewWorkBar();

   //--- act on the freshly computed signals
   Trade_OnSignals();

   //--- refresh dashboard
   if(InpShowDashboard) Dash_Update();
  }
//+------------------------------------------------------------------+
