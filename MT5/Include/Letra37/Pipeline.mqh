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
#property strict

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
   EntryCycleExec_Compute(); // F72 entry-cycle execution signal
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
