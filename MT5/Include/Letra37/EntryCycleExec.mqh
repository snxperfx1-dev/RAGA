//+------------------------------------------------------------------+
//|  EntryCycleExec.mqh - F72 entry-cycle EXECUTION signal           |
//|                                                                  |
//|  Makes the recursive-curve framework executable: the spec says   |
//|  the decisive event is not a phase label but the moment the      |
//|  ENTRY CYCLE becomes active at the HTF terminal (flip/supply/     |
//|  demand) zone - "once the entry cycle starts, hesitation gets    |
//|  you left behind." This engine fires ONE signal per entry-cycle  |
//|  activation, trading WITH the curve that has won ownership of     |
//|  the terminal zone (the new campaign / reversal), once:          |
//|    * campaign is TERMINAL (price at the HTF flip zone), and       |
//|    * entry readiness is ENTRY ACTIVE or TERMINAL, and             |
//|    * the recursive entry cycle has matured (Wyckoff shifts >=     |
//|      InpEcMinWyckoff - distinguishing the entry cycle from the    |
//|      first strike), and                                          |
//|    * dominance has transferred (transferring/complete) if         |
//|      required.                                                   |
//|                                                                  |
//|  This is ADDITIVE to the precise Letra trigger (both can fire)   |
//|  and is OFF by default. It adds no conflict safety / gating to    |
//|  the Letra entries.                                              |
//+------------------------------------------------------------------+
#property strict

//================= EC EXECUTION OUTPUTS ===========================
bool   sigEC_long=false;
bool   sigEC_short=false;
int    ec_dir=0;
bool   ec_active=false;
bool   ec_ready=false;

//--- one-shot latch per entry-cycle activation
bool   g_ec_fired=false;

void EntryCycleExec_Init(){ g_ec_fired=false; sigEC_long=false; sigEC_short=false; }

void EntryCycleExec_Compute()
  {
   sigEC_long=false; sigEC_short=false;

   ec_active = (co_campaign=="TERMINAL") &&
               (co_entryReadiness=="ENTRY ACTIVE" || co_entryReadiness=="TERMINAL");

   //--- trade WITH the curve that owns the terminal zone (the new campaign).
   //    Prefer the curve-tree owner; fall back to the MTF owner direction.
   ec_dir = ec_active ? (ct_ownDir!=0 ? ct_ownDir : mo_dir) : 0;

   bool wyckOK = mo_wyckoffShifts >= InpEcMinWyckoff;
   bool xferOK = (!InpEcRequireTransfer) ||
                 (mo_transferState=="TRANSFERRING" || mo_transferState=="COMPLETE" || ct_transferred);
   ec_ready = ec_active && ec_dir!=0 && wyckOK && xferOK;

   //--- reset the latch when we leave the terminal/entry-cycle environment
   if(!ec_active) g_ec_fired=false;

   bool fireOK = ec_ready && !g_ec_fired;
   sigEC_long  = fireOK && ec_dir==1;
   sigEC_short = fireOK && ec_dir==-1;
   if(fireOK) g_ec_fired=true;
  }
//+------------------------------------------------------------------+
