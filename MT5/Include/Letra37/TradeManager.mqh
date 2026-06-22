//+------------------------------------------------------------------+
//|  TradeManager.mqh - execution + risk management                  |
//|                                                                  |
//|  Consumes the engine signals (sig_longSignal / sig_shortSignal / |
//|  sig_exitNow / sig_tradeDir) and runs autonomous order           |
//|  management with hedge-fund-grade controls:                      |
//|    * risk-% position sizing from the stop distance               |
//|    * structural (flip-zone / invalidation) or ATR stops          |
//|    * ATR take-profit, ATR trailing stop, breakeven               |
//|    * spread filter, session filter, max-positions cap            |
//|    * daily-loss limit and total-drawdown circuit breaker         |
//+------------------------------------------------------------------+
#property strict

CTrade g_trade;

//--- cached symbol info
double tm_point=0, tm_tickSize=0, tm_tickValue=0, tm_volMin=0, tm_volMax=0, tm_volStep=0;
int    tm_digits=0; long tm_stopLevel=0;

//--- risk-state tracking
double tm_peakEquity=0;
double tm_dayStartEquity=0;
int    tm_dayStamp=-1;
bool   tm_halted=false;

//==================================================================
void Trade_Init()
  {
   tm_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   tm_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   tm_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   tm_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   tm_volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   tm_volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   tm_volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   tm_stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(tm_tickSize<=0) tm_tickSize=tm_point;
   tm_peakEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   tm_dayStartEquity = tm_peakEquity;
   tm_dayStamp       = -1;
   tm_halted         = false;
  }

//==================================================================
//  Helpers
//==================================================================
int Trade_CountPositions()
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      n++;
     }
   return n;
  }

//--- net direction of EA positions (+1 long, -1 short, 0 none/mixed)
int Trade_NetDir()
  {
   int dir=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      int pd=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
      if(dir==0) dir=pd; else if(dir!=pd) return 0;
     }
   return dir;
  }

void Trade_CloseAll(const string why)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      g_trade.PositionClose(tk);
     }
  }

double Trade_NormalizeLots(double lots)
  {
   if(tm_volStep>0) lots = MathFloor(lots/tm_volStep)*tm_volStep;
   lots = MathMax(tm_volMin, MathMin(tm_volMax, lots));
   //--- round to step decimals
   int dec=0; double s=tm_volStep;
   while(s<1.0 && dec<8){ s*=10.0; dec++; }
   return NormalizeDouble(lots, dec);
  }

//--- lot size from risk% and stop distance (price units)
double Trade_LotsForRisk(const double stopDistPrice)
  {
   if(InpFixedLots>0.0) return Trade_NormalizeLots(InpFixedLots);
   if(stopDistPrice<=0 || tm_tickSize<=0 || tm_tickValue<=0) return tm_volMin;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity*InpRiskPercent/100.0;
   double ticks = stopDistPrice/tm_tickSize;
   double lossPerLot = ticks*tm_tickValue;
   if(lossPerLot<=0) return tm_volMin;
   double lots = riskMoney/lossPerLot;
   return Trade_NormalizeLots(lots);
  }

//--- session / day filters
bool Trade_SessionOK()
  {
   if(!InpUseSession) return true;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(!InpTradeMonday && t.day_of_week==1) return false;
   if(!InpTradeFriday && t.day_of_week==5) return false;
   if(t.day_of_week==0 || t.day_of_week==6) return false;
   int h=t.hour;
   if(InpSessionStartHr<=InpSessionEndHr)
      return(h>=InpSessionStartHr && h<InpSessionEndHr);
   else
      return(h>=InpSessionStartHr || h<InpSessionEndHr); // wraps midnight
  }

bool Trade_SpreadOK()
  {
   if(InpMaxSpreadPoints<=0) return true;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sp=(ask-bid)/MathMax(tm_point,1e-10);
   return(sp<=InpMaxSpreadPoints);
  }

//--- risk circuit breakers (daily loss + total drawdown)
void Trade_UpdateRiskState()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity>tm_peakEquity) tm_peakEquity=equity;

   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   int stamp = t.year*1000+t.day_of_year;
   if(stamp!=tm_dayStamp){ tm_dayStamp=stamp; tm_dayStartEquity=equity; }

   tm_halted=false;
   if(InpMaxDailyLossPct>0.0)
     {
      double dd = (tm_dayStartEquity-equity)/MathMax(tm_dayStartEquity,1e-10)*100.0;
      if(dd>=InpMaxDailyLossPct) tm_halted=true;
     }
   if(InpMaxTotalDDPct>0.0)
     {
      double tdd = (tm_peakEquity-equity)/MathMax(tm_peakEquity,1e-10)*100.0;
      if(tdd>=InpMaxTotalDDPct) tm_halted=true;
     }
  }

//==================================================================
//  Entry & exit on each new work bar
//==================================================================
void Trade_OnSignals()
  {
   if(!InpEnableTrading) return;
   Trade_UpdateRiskState();

   //--- engine EXIT
   if(sig_exitNow && Trade_CountPositions()>0)
     {
      Trade_CloseAll("engine exit");
      return;
     }
   //--- close on direction flip if requested
   if(InpCloseOnExit)
     {
      int nd=Trade_NetDir();
      if(nd==1 && sig_shortSignal) Trade_CloseAll("flip to short");
      if(nd==-1 && sig_longSignal) Trade_CloseAll("flip to long");
     }

   //--- F72 curve-life management (DEAD exits / WEAKENING breakeven)
   Trade_ManageCurveLife();

   if(tm_halted) return;                 // risk circuit breaker
   if(!Trade_SessionOK()) return;
   if(!Trade_SpreadOK())  return;

   bool wantLong  = sig_longSignal;
   bool wantShort = sig_shortSignal;
   string tag = "letra";

   //--- ADDITIVE entry-cycle execution path (F72) - never gates Letra
   if(InpUseEntryCycleExec)
     {
      if(sigEC_long  && !wantLong ){ wantLong =true; tag="entry-cycle"; }
      if(sigEC_short && !wantShort){ wantShort=true; tag="entry-cycle"; }
     }
   if(!wantLong && !wantShort) return;

   //--- respect position cap & avoid stacking same dir
   int nd=Trade_NetDir();
   if(Trade_CountPositions()>=InpMaxPositions) return;
   if(wantLong  && nd==1)  return;       // already long
   if(wantShort && nd==-1) return;       // already short

   if(wantLong)       Trade_Open(1,  tag);
   else if(wantShort) Trade_Open(-1, tag);
  }

//==================================================================
//  Open a position in `dir` (+1 long / -1 short) with risk-% sizing
//  and structural/ATR stop + ATR take-profit. Shared by the Letra
//  trigger and the entry-cycle execution path.
//==================================================================
void Trade_Open(const int dir,const string tag)
  {
   double atrv = IsNa(atr) ? 0.0 : atr;
   if(atrv<=0) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double minStop = (double)tm_stopLevel*tm_point;

   if(dir==1)
     {
      double entry=ask;
      double sl = (InpUseStructSL && !IsNa(flipBot)) ? MathMin(flipBot,!IsNa(l0_inv)?l0_inv:flipBot)-atrv*0.25 : entry-atrv*InpSL_ATR;
      if(entry-sl < minStop) sl = entry-minStop-tm_point;
      double tp = (InpTP_ATR>0.0) ? entry+atrv*InpTP_ATR : 0.0;
      double lots = Trade_LotsForRisk(entry-sl);
      sl=NormalizeDouble(sl,tm_digits); if(tp>0) tp=NormalizeDouble(tp,tm_digits);
      if(!g_trade.Buy(lots,_Symbol,0.0,sl,tp,InpTradeComment+" "+tag))
         PrintFormat("Letra37 BUY failed: %d %s",g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      else
         PrintFormat("Letra37 BUY [%s] %.2f lots sl=%.5f tp=%.5f grade=%s prob=%.0f",tag,lots,sl,tp,sig_grade,sig_finalProb);
     }
   else if(dir==-1)
     {
      double entry=bid;
      double sl = (InpUseStructSL && !IsNa(flipTop)) ? MathMax(flipTop,!IsNa(l0_inv)?l0_inv:flipTop)+atrv*0.25 : entry+atrv*InpSL_ATR;
      if(sl-entry < minStop) sl = entry+minStop+tm_point;
      double tp = (InpTP_ATR>0.0) ? entry-atrv*InpTP_ATR : 0.0;
      double lots = Trade_LotsForRisk(sl-entry);
      sl=NormalizeDouble(sl,tm_digits); if(tp>0) tp=NormalizeDouble(tp,tm_digits);
      if(!g_trade.Sell(lots,_Symbol,0.0,sl,tp,InpTradeComment+" "+tag))
         PrintFormat("Letra37 SELL failed: %d %s",g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      else
         PrintFormat("Letra37 SELL [%s] %.2f lots sl=%.5f tp=%.5f grade=%s prob=%.0f",tag,lots,sl,tp,sig_grade,sig_finalProb);
     }
  }

//==================================================================
//  F72 curve-life management of OPEN trades (per closed work bar).
//  Manage-only: never opens or gates entries.
//    DEAD (owning curve died) -> abandon a with-owner position
//    WEAKENING                -> move SL to breakeven if in profit
//==================================================================
void Trade_ManageCurveLife()
  {
   if(!InpEnableTrading || !InpUseCurveLife) return;
   int nd=Trade_NetDir();
   if(nd==0) return;

   //--- owning curve is DEAD and we hold a position aligned with it -> exit
   if(InpCurveLifeFlatOnDead && cl_state=="DEAD" && nd==cl_ownDir)
     {
      Trade_CloseAll("curve-life DEAD");
      return;
     }

   //--- WEAKENING -> lock breakeven on any position that is in profit
   if(InpCurveLifeTightenWeak && cl_state=="WEAKENING")
     {
      double point=tm_point;
      double minStop=(double)tm_stopLevel*point;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
         int    ptype=(int)PositionGetInteger(POSITION_TYPE);
         double open =PositionGetDouble(POSITION_PRICE_OPEN);
         double curSL=PositionGetDouble(POSITION_SL);
         double curTP=PositionGetDouble(POSITION_TP);
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         if(ptype==POSITION_TYPE_BUY)
           {
            double be=open+point*2;
            if(bid-open>0 && (curSL<be) && (bid-be)>=minStop)
               g_trade.PositionModify(tk, NormalizeDouble(be,tm_digits), curTP);
           }
         else if(ptype==POSITION_TYPE_SELL)
           {
            double be=open-point*2;
            if(open-ask>0 && (curSL>be || curSL==0.0) && (be-ask)>=minStop)
               g_trade.PositionModify(tk, NormalizeDouble(be,tm_digits), curTP);
           }
        }
     }
  }

//==================================================================
//  Intrabar management: trailing stop + breakeven (every tick)
//==================================================================
void Trade_ManageOpen()
  {
   if(!InpEnableTrading) return;
   if(!InpUseTrailing && !InpUseBreakeven) return;
   double atrv = IsNa(atr) ? 0.0 : atr;
   if(atrv<=0) return;

   double point=tm_point;
   double minStop=(double)tm_stopLevel*point;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      int    ptype = (int)PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double newSL = curSL;

      if(ptype==POSITION_TYPE_BUY)
        {
         double profit = bid-open;
         //--- breakeven
         if(InpUseBreakeven && profit>=atrv*InpBE_ATR)
           {
            double be=open+point*2;
            if(curSL<be) newSL=MathMax(newSL,be);
           }
         //--- trailing
         if(InpUseTrailing && profit>=atrv*InpTrailStartATR)
           {
            double trail=bid-atrv*InpTrailATR;
            if(trail>newSL) newSL=trail;
           }
         if(newSL>curSL && (bid-newSL)>=minStop)
            g_trade.PositionModify(tk, NormalizeDouble(newSL,tm_digits), curTP);
        }
      else if(ptype==POSITION_TYPE_SELL)
        {
         double profit = open-ask;
         if(InpUseBreakeven && profit>=atrv*InpBE_ATR)
           {
            double be=open-point*2;
            if(curSL>be || curSL==0.0) newSL=(curSL==0.0)?be:MathMin(newSL,be);
           }
         if(InpUseTrailing && profit>=atrv*InpTrailStartATR)
           {
            double trail=ask+atrv*InpTrailATR;
            if(trail<newSL || curSL==0.0) newSL=(curSL==0.0)?trail:MathMin(newSL,trail);
           }
         if(newSL!=curSL && newSL>0 && (newSL-ask)>=minStop)
            g_trade.PositionModify(tk, NormalizeDouble(newSL,tm_digits), curTP);
        }
     }
  }
//+------------------------------------------------------------------+
