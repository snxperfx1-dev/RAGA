//+------------------------------------------------------------------+
//|  Dashboard.mqh - on-chart status panel                           |
//|                                                                  |
//|  Renders the engine's live state via Comment() (reliable         |
//|  multi-line). Mirrors the decision-relevant readouts of the      |
//|  original dashboards.                                            |
//+------------------------------------------------------------------+
#property strict

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
   s += "EntryExec : "+(InpUseEntryCycleExec?"ON":"off")+"  "+(ec_active?"ACTIVE":"-")+(ec_ready?" READY "+DirWord(ec_dir):"")+(sigEC_long?"  >> EC LONG":sigEC_short?"  >> EC SHORT":"") + nl;
   s += "TimeIntel : dir "+DirWord(timeDir)+"  align "+DoubleToString(timeAlign,0)+"%   H1 "+h1Timing+" ("+tH1State+")" + nl;
   s += "TradeState: " + (tradeDir==1?"LONG":tradeDir==-1?"SHORT":"FLAT") + "   positions "+IntegerToString(Trade_CountPositions()) + nl;
   s += "Vol regime: " + phys_volRegime + "  ATR "+DoubleToString(IsNa(atr)?0.0:atr,_Digits);

   Comment(s);
  }
//+------------------------------------------------------------------+
