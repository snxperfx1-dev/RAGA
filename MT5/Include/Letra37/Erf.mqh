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
#property strict

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
