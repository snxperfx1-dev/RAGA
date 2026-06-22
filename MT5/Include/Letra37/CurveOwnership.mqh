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
#property strict

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

   //--- recursion depth + dominance transfer (from the structure engine)
   co_recDepth = (int)se5_rec;
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
