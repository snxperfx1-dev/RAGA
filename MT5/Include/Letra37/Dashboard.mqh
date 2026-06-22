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
   s += "TradeState: " + (tradeDir==1?"LONG":tradeDir==-1?"SHORT":"FLAT") + "   positions "+IntegerToString(Trade_CountPositions()) + nl;
   s += "Vol regime: " + phys_volRegime + "  ATR "+DoubleToString(IsNa(atr)?0.0:atr,_Digits);

   Comment(s);
  }
//+------------------------------------------------------------------+
