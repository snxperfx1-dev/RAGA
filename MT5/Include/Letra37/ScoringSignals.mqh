//+------------------------------------------------------------------+
//|  ScoringSignals.mqh - scoring, Bayesian, opportunity, signals    |
//|  [STUB - implemented in Parts 9 & 10]                            |
//+------------------------------------------------------------------+
#property strict
//--- signal outputs consumed by the trade manager
bool   sig_longSignal   = false;
bool   sig_shortSignal  = false;
bool   sig_exitNow      = false;
int    sig_tradeDir     = 0;
double sig_finalProb    = 0.0;
string sig_grade        = "D";
double sig_netEdgeAdj   = 0.0;
string sig_directive    = "NO TRADE / STAND DOWN";

void Signals_Init() {}
void Signals_Compute() {}
//+------------------------------------------------------------------+
