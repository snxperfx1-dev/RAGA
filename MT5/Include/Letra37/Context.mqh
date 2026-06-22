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
   //--- collect closed bars (shift>=1) with closeTime<=moment and openTime>lastOpenTime
   //--- iterate from oldest unprocessed to newest closed (shift 1)
   //--- find max shift to consider (cap to ring capacity)
   int maxShift = (int)MathMin(bars-1, CTX_RING_CAP-2);
   //--- gather descending then reverse
   int tmp[];
   ArrayResize(tmp,0);
   for(int s=maxShift; s>=1; s--)
     {
      datetime ot = iTime(_Symbol, tf, s);
      if(ot==0) continue;
      datetime ct = (datetime)(ot + per);
      if(ot>lastOpenTime && ct<=moment)
        {
         int n=ArraySize(tmp); ArrayResize(tmp,n+1); tmp[n]=s;
        }
     }
   //--- tmp is already oldest->newest because s descends (older bars have larger shift)
   ArrayResize(shiftsOut, ArraySize(tmp));
   for(int i=0;i<ArraySize(tmp);i++) shiftsOut[i]=tmp[i];
   return ArraySize(shiftsOut);
  }
//+------------------------------------------------------------------+
