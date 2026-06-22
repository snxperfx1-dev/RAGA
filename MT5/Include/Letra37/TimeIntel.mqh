//+------------------------------------------------------------------+
//|  TimeIntel.mqh - Time Intelligence Engine (TIE)                  |
//|                                                                  |
//|  Tracks each higher cycle (Monthly / Weekly / Daily / H4 / H1):  |
//|  is its high / low already taken, is it opening / expanding /    |
//|  mid / terminal, and which way it is biased from its open.       |
//|  Produces a cross-cycle timing read (timeDir / timeAlign /       |
//|  timeConflict) and the H1 timing call. This is CONTEXT for trade |
//|  management and timing - it does NOT gate the Letra entries.     |
//|                                                                  |
//|  Stateless per work bar: reads each cycle's running bar (shift 0)|
//|  and prior bar (shift 1) directly, so no feeder is required.     |
//+------------------------------------------------------------------+
#property strict

//================= TIE OUTPUTS ====================================
int    timeDir=0;
double timeAlign=50.0, timeConflict=50.0;
string h1Timing="BALANCED";
double h1LowProb=50.0;

//--- per-cycle state (for management + dashboard)
bool   tMnHt=false,tMnLt=false, tWHt=false,tWLt=false, tDHt=false,tDLt=false, tH4Ht=false,tH4Lt=false, tH1Ht=false,tH1Lt=false;
int    tMnBias=0,tWBias=0,tDBias=0,tH4Bias=0,tH1Bias=0;
string tH1State="—", tH4State="—", tDState="—";

void TimeIntel_Init() {}

//--- cycle elapsed fraction 0..1
double TIE_Elapsed(const ENUM_TIMEFRAMES tf)
  {
   int per=PeriodSeconds(tf);
   if(per<=0) return 0.0;
   datetime ot=iTime(_Symbol,tf,0);
   if(ot==0) return 0.0;
   return Clamp((double)(TimeCurrent()-ot)/(double)per, 0.0, 1.0);
  }

string TIE_State(const bool ht,const bool lt,const double el)
  {
   if(ht && lt) return "DUAL DONE";
   if(ht)       return "HIGH DONE";
   if(lt)       return "LOW DONE";
   if(el<0.15)  return "OPENING";
   if(el<0.6)   return "EXPANDING";
   if(el<0.9)   return "MID CYCLE";
   return "TERMINAL";
  }

//--- evaluate one cycle: bias / high-taken / low-taken
void TIE_Cycle(const ENUM_TIMEFRAMES tf,const double cl,int &bias,bool &ht,bool &lt)
  {
   double o =iOpen (_Symbol,tf,0);
   double h =iHigh (_Symbol,tf,0);
   double lo=iLow  (_Symbol,tf,0);
   double ph=iHigh (_Symbol,tf,1);
   double pl=iLow  (_Symbol,tf,1);
   bias = cl>o?1:cl<o?-1:0;
   ht = (h>ph);
   lt = (lo<pl);
  }

void TimeIntel_Compute()
  {
   double cl=C_close();
   if(IsNa(cl)) return;

   TIE_Cycle(PERIOD_MN1, cl, tMnBias, tMnHt, tMnLt);
   TIE_Cycle(PERIOD_W1,  cl, tWBias,  tWHt,  tWLt);
   TIE_Cycle(PERIOD_D1,  cl, tDBias,  tDHt,  tDLt);
   TIE_Cycle(PERIOD_H4,  cl, tH4Bias, tH4Ht, tH4Lt);
   TIE_Cycle(PERIOD_H1,  cl, tH1Bias, tH1Ht, tH1Lt);

   tH1State = TIE_State(tH1Ht, tH1Lt, TIE_Elapsed(PERIOD_H1));
   tH4State = TIE_State(tH4Ht, tH4Lt, TIE_Elapsed(PERIOD_H4));
   tDState  = TIE_State(tDHt,  tDLt,  TIE_Elapsed(PERIOD_D1));

   int tBull = (tMnBias==1?1:0)+(tWBias==1?1:0)+(tDBias==1?1:0)+(tH4Bias==1?1:0)+(tH1Bias==1?1:0);
   int tBear = (tMnBias==-1?1:0)+(tWBias==-1?1:0)+(tDBias==-1?1:0)+(tH4Bias==-1?1:0)+(tH1Bias==-1?1:0);
   timeDir   = tBull>tBear ? 1 : tBear>tBull ? -1 : 0;
   timeAlign = (tBull+tBear)>0 ? (double)MathMax(tBull,tBear)/(tBull+tBear)*100.0 : 50.0;
   timeConflict = 100.0 - timeAlign;

   //--- H1 low-probability + timing call
   double h1O=iOpen(_Symbol,PERIOD_H1,0), h1H=iHigh(_Symbol,PERIOD_H1,0), h1L=iLow(_Symbol,PERIOD_H1,0);
   double pos=(cl-h1L)/MathMax(h1H-h1L, _Point);
   h1LowProb = (tH1Lt && !tH1Ht) ? 30.0 : (tH1Ht && !tH1Lt) ? 70.0 : MathRound(pos*100.0);
   h1Timing = (tH1Ht && tH1Lt) ? "COMPLETION" : h1LowProb>=55 ? "LOW FIRST" : h1LowProb<=45 ? "HIGH FIRST" : "BALANCED";
  }
//+------------------------------------------------------------------+
