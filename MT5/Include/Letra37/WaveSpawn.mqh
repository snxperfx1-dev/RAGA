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
#property strict

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
