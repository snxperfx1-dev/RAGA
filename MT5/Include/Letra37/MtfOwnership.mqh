//+------------------------------------------------------------------+
//|  MtfOwnership.mqh - Multi-Timeframe Curve Ownership Engine       |
//|                                                                  |
//|  Principle 12/14, Priority Level 1: every timeframe runs its own |
//|  recursive curve simultaneously (M1..H4). This engine reads each |
//|  rung's own curve state (direction, wave progress, compression,  |
//|  recursion count, dominance transfer) and rolls them into the    |
//|  single question that matters most:                              |
//|                                                                  |
//|    WHICH CURVE CURRENTLY OWNS PRICE  (H4 70% / H1 20% / M5 10%)  |
//|                                                                  |
//|  plus the TRANSFER-STATE ladder (Stable -> Building -> Contested |
//|  -> Transferring -> Complete), the Wyckoff FOUR-SHIFT count at   |
//|  terminal/transition zones (spring/test/LPS1/LPS2 = always 4),   |
//|  and the ENTRY ARCHITECTURE (wide large-recursion vs compressed  |
//|  failure-swing) that decides how the entry cycle will build.     |
//|                                                                  |
//|  Context + management read only; never gates the Letra trigger.  |
//+------------------------------------------------------------------+
#property strict

//================= OWNERSHIP MAP OUTPUTS ==========================
double mo_pct[6];                 // ownership % per rung (M1,M3,M5,M15,H1,H4)
string mo_lbl[6];                 // rung labels
int    mo_dirArr[6];              // rung directions
int    mo_ownerIdx=2, mo_secondIdx=4;
double mo_ownerPct=0.0, mo_secondPct=0.0;
string mo_ownerLabel="M5", mo_secondLabel="H1";
int    mo_dir=0;                  // owning rung direction
string mo_transferState="STABLE"; // STABLE|BUILDING|CONTESTED|TRANSFERRING|COMPLETE
int    mo_wyckoffShifts=0;        // shifts toward the canonical 4
bool   mo_fourShiftDone=false;
string mo_entryArch="MIXED";      // WIDE | COMPRESSION | MIXED
int    mo_expectedEntries=1;

void MtfOwnership_Init() {}

//--- rung label from the adaptive ladder
string MO_TFLabel(const ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1:  return "M1";   case PERIOD_M3:  return "M3";  case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";  case PERIOD_M30: return "M30"; case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";   case PERIOD_D1:  return "D1";  case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";   default: return EnumToString(tf);
     }
  }

void MtfOwnership_Compute()
  {
   //--- per-rung curve state (each timeframe's own recursive curve)
   mo_dirArr[0]=m1_dir; mo_dirArr[1]=l3_dir; mo_dirArr[2]=l0_dir;
   mo_dirArr[3]=l1_dir; mo_dirArr[4]=l2_dir; mo_dirArr[5]=l4_dir;
   double wp[6];   wp[0]=se1_wp;  wp[1]=se3_wp;  wp[2]=se5_wp;  wp[3]=se15_wp;  wp[4]=se60_wp;  wp[5]=se240_wp;
   double dom[6];  dom[0]=se1_dom;dom[1]=se3_dom;dom[2]=se5_dom;dom[3]=se15_dom;dom[4]=se60_dom;dom[5]=se240_dom;
   //--- contextual timeframe authority (higher TF carries more weight)
   double tfW[6];  tfW[0]=0.04; tfW[1]=0.06; tfW[2]=0.14; tfW[3]=0.20; tfW[4]=0.26; tfW[5]=0.30;

   mo_lbl[0]=MO_TFLabel(g_ladderTF[0]); mo_lbl[1]=MO_TFLabel(g_ladderTF[1]); mo_lbl[2]=MO_TFLabel(g_ladderTF[2]);
   mo_lbl[3]=MO_TFLabel(g_ladderTF[3]); mo_lbl[4]=MO_TFLabel(g_ladderTF[4]); mo_lbl[5]=MO_TFLabel(g_ladderTF[5]);

   //--- ownership weight: a curve owns price when it is mid-progress (actively
   //    delivering) and carries dominance/recursion energy, scaled by TF authority.
   double raw[6]; double tot=0.0;
   for(int i=0;i<6;i++)
     {
      double midW = MathMax(0.0, 1.0 - MathAbs(wp[i]-50.0)/55.0);   // peaks at mid-progress
      raw[i] = tfW[i] * (0.5 + 0.5*midW) * (1.0 + dom[i]/200.0);
      tot += raw[i];
     }
   mo_ownerIdx=0; mo_secondIdx=1; mo_ownerPct=0.0; mo_secondPct=0.0;
   for(int i=0;i<6;i++)
     {
      mo_pct[i] = tot>0.0 ? raw[i]/tot*100.0 : 0.0;
      if(mo_pct[i]>mo_ownerPct){ mo_secondPct=mo_ownerPct; mo_secondIdx=mo_ownerIdx; mo_ownerPct=mo_pct[i]; mo_ownerIdx=i; }
      else if(mo_pct[i]>mo_secondPct){ mo_secondPct=mo_pct[i]; mo_secondIdx=i; }
     }
   mo_ownerLabel=mo_lbl[mo_ownerIdx];
   mo_secondLabel=mo_lbl[mo_secondIdx];
   mo_dir = mo_dirArr[mo_ownerIdx];

   //--- transfer-state ladder (dominance within the owning curve + contest gap)
   double domOwner = dom[mo_ownerIdx];
   double gap = mo_ownerPct - mo_secondPct;
   mo_transferState =
        domOwner>=70.0 ? "COMPLETE" :
        domOwner>=50.0 ? "TRANSFERRING" :
        gap<12.0       ? "CONTESTED" :
        domOwner>=40.0 ? "BUILDING" : "STABLE";

   //--- Wyckoff four-shift (only meaningful at terminal/transition zones)
   bool terminal = (co_campaign=="TERMINAL");
   mo_wyckoffShifts = terminal ? (int)MathMin(4.0, se5_rec) : 0;
   mo_fourShiftDone = terminal && (se5_rec>=4.0 || co_transferComplete);

   //--- entry architecture from terminal compression (Model A wide vs Model B tight)
   double comp = se5_comp;
   mo_entryArch = comp>=60.0 ? "COMPRESSION (failure-swing + tiny recursions)" :
                  comp<25.0  ? "WIDE (large recursions)" : "MIXED";
   mo_expectedEntries = comp>=75.0 ? 4 : comp>=50.0 ? 3 : comp>=25.0 ? 2 : 1;
  }
//+------------------------------------------------------------------+
