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
#property strict

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
