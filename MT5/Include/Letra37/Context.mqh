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
#property strict

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
