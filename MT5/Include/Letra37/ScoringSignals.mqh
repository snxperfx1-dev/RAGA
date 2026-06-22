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
#property strict

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
