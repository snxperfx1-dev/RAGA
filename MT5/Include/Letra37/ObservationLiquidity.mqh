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
#property strict

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
