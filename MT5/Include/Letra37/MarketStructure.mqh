//+------------------------------------------------------------------+
//|  MarketStructure.mqh - SECTIONS 4-8 (chart context)             |
//|                                                                  |
//|  Section 4  : structure pivots (HH/HL/LH/LL), swing BOS/CHoCH,   |
//|               structBias, structLongOK/structShortOK             |
//|  Section 5  : pivot memory (last/prev pivot price/bar/dir)       |
//|  Section 6  : elite impulse detection                            |
//|  Section 7  : f_findInducPrice (inducement/flipzone finder)      |
//|  Section 8  : wave-context accept-bars range helpers             |
//|                                                                  |
//|  Runs on the working-timeframe series (g_H/g_L/g_C) after the    |
//|  current bar has been pushed; pivots use the same ta.pivot*      |
//|  confirm-at-current-bar semantics as the source.                 |
//+------------------------------------------------------------------+
#property strict

//================= GLOBAL OUTPUTS =================================
double structPivH=PINE_NA, structPivL=PINE_NA;
double lastPivHigh=PINE_NA, prevPivHigh=PINE_NA, lastPivLow=PINE_NA, prevPivLow=PINE_NA;
int    structBias=0;
bool   isHH=false, isLH=false, isHL=false, isLL=false;

double prevSwingHigh=PINE_NA, prevSwingLow=PINE_NA, currSwingHigh=PINE_NA, currSwingLow=PINE_NA;
bool   bullBOS=false, bearBOS=false, bullCHoCH=false, bearCHoCH=false;
bool   structLongOK=false, structShortOK=false;

double pivH=PINE_NA, pivL=PINE_NA;
double lastPivotPrice=PINE_NA, prevPivotPrice=PINE_NA;
long   lastPivotBar=-1, prevPivotBar=-1;
int    lastPivotDir=0, prevPivotDir=0;

bool   eliteShortImpulse=false, eliteLongImpulse=false;

double g_highestAB=PINE_NA, g_lowestAB=PINE_NA;

//==================================================================
void MS_Init()
  {
   structPivH=PINE_NA; structPivL=PINE_NA;
   lastPivHigh=PINE_NA; prevPivHigh=PINE_NA; lastPivLow=PINE_NA; prevPivLow=PINE_NA;
   structBias=0; isHH=false; isLH=false; isHL=false; isLL=false;
   prevSwingHigh=PINE_NA; prevSwingLow=PINE_NA; currSwingHigh=PINE_NA; currSwingLow=PINE_NA;
   bullBOS=false; bearBOS=false; bullCHoCH=false; bearCHoCH=false;
   structLongOK=false; structShortOK=false;
   pivH=PINE_NA; pivL=PINE_NA;
   lastPivotPrice=PINE_NA; prevPivotPrice=PINE_NA; lastPivotBar=-1; prevPivotBar=-1;
   lastPivotDir=0; prevPivotDir=0;
   eliteShortImpulse=false; eliteLongImpulse=false;
  }

//==================================================================
//  Section 7: f_findInducPrice
//  Scans i=1..min(lookback, barIndex-anchorRefBar). A qualifying bar
//  has high[i] < top and low[i] > bot. Returns the midpoint of the
//  qualifying bar whose absolute bar-distance to anchorRefBar is
//  smallest; PINE_NA if none.
//==================================================================
double FindInducPrice(const long anchorRefBar,const double top,const double bot,const int lookback)
  {
   if(IsNa(top) || IsNa(bot) || anchorRefBar<0) return PINE_NA;
   long span = g_barIndex - anchorRefBar;
   int maxI = (int)MathMin((long)lookback, span);
   double best=PINE_NA, bestDist=PINE_NA;
   for(int i=1;i<=maxI;i++)
     {
      double hi=g_H.Get(i), lo=g_L.Get(i);
      if(IsNa(hi)||IsNa(lo)) continue;
      if(hi<top && lo>bot)
        {
         double d=MathAbs((double)((g_barIndex-i)-anchorRefBar));
         if(IsNa(bestDist) || d<bestDist){ bestDist=d; best=(hi+lo)/2.0; }
        }
     }
   return best;
  }

//==================================================================
void MS_Compute()
  {
   double cl=C_close();
   double atrv = IsNa(atr)?0.0:atr;

   //==================== SECTION 4 ===============================
   structPivH = PivotHigh(g_H, cfg_structLen);
   structPivL = PivotLow (g_L, cfg_structLen);

   if(!IsNa(structPivH)){ prevPivHigh=lastPivHigh; lastPivHigh=structPivH; }
   if(!IsNa(structPivL)){ prevPivLow =lastPivLow;  lastPivLow =structPivL; }

   isHH = (!IsNa(lastPivHigh)&&!IsNa(prevPivHigh)&&lastPivHigh>prevPivHigh);
   isLH = (!IsNa(lastPivHigh)&&!IsNa(prevPivHigh)&&lastPivHigh<prevPivHigh);
   isHL = (!IsNa(lastPivLow) &&!IsNa(prevPivLow) &&lastPivLow >prevPivLow);
   isLL = (!IsNa(lastPivLow) &&!IsNa(prevPivLow) &&lastPivLow <prevPivLow);

   double swPivH = PivotHigh(g_H, cfg_pivotLen);
   double swPivL = PivotLow (g_L, cfg_pivotLen);

   if(!IsNa(swPivH)){ prevSwingHigh = IsNa(currSwingHigh)?swPivH:currSwingHigh; currSwingHigh=swPivH; }
   if(!IsNa(swPivL)){ prevSwingLow  = IsNa(currSwingLow) ?swPivL:currSwingLow;  currSwingLow =swPivL; }

   bullBOS  = (!IsNa(prevSwingHigh)) && (cl>prevSwingHigh);
   bearBOS  = (!IsNa(prevSwingLow))  && (cl<prevSwingLow);
   bullCHoCH= (!IsNa(prevSwingHigh)) && (cl>prevSwingHigh+atrv*cfg_chochBufferATR);
   bearCHoCH= (!IsNa(prevSwingLow))  && (cl<prevSwingLow -atrv*cfg_chochBufferATR);

   if(cfg_useStrictStruct)
     {
      if(isHH && isHL) structBias=1;
      if(isLH && isLL) structBias=-1;
     }
   else
     {
      if(bullBOS) structBias=1;
      if(bearBOS) structBias=-1;
     }

   structLongOK  = (!cfg_requireStruct) ||
                   (cfg_useStrictStruct && structBias==1 && isHH) ||
                   (!cfg_useStrictStruct && structBias==1);
   structShortOK = (!cfg_requireStruct) ||
                   (cfg_useStrictStruct && structBias==-1 && isLL) ||
                   (!cfg_useStrictStruct && structBias==-1);

   //==================== SECTION 5 (pivot memory) ================
   pivH = swPivH;   // ta.pivothigh(high,pivotLen) - same as swing pivot
   pivL = swPivL;

   double evtPrice=PINE_NA; long evtBar=-1; int evtDir=0;
   if(!IsNa(pivH)){ evtPrice=pivH; evtBar=g_barIndex-cfg_pivotLen; evtDir=1; }
   else if(!IsNa(pivL)){ evtPrice=pivL; evtBar=g_barIndex-cfg_pivotLen; evtDir=-1; }
   if(evtDir!=0)
     {
      prevPivotPrice=lastPivotPrice; prevPivotBar=lastPivotBar; prevPivotDir=lastPivotDir;
      lastPivotPrice=evtPrice; lastPivotBar=evtBar; lastPivotDir=evtDir;
     }

   //==================== SECTION 6 (elite impulse) ===============
   eliteShortImpulse = (!IsNa(pivL)) && prevPivotDir==1  && (!IsNa(prevPivotPrice)) && ((prevPivotPrice-pivL)>atrv*cfg_impulseAtrMult);
   eliteLongImpulse  = (!IsNa(pivH)) && prevPivotDir==-1 && (!IsNa(prevPivotPrice)) && ((pivH-prevPivotPrice)>atrv*cfg_impulseAtrMult);

   //==================== SECTION 8 (accept-bars range) ===========
   g_highestAB = g_H.Highest(cfg_acceptBars);
   g_lowestAB  = g_L.Lowest (cfg_acceptBars);
  }
//+------------------------------------------------------------------+
