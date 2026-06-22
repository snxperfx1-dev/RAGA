//+------------------------------------------------------------------+
//|  CurveLife.mqh - F72 "is the trade alive?" engine                |
//|                                                                  |
//|  Instead of asking how deep a move retraces, it asks whether the |
//|  COUNTER side can even build a move here. It scores the live      |
//|  campaign as ALIVE (hold) / WEAKENING (manage) / DEAD (flip), and |
//|  adds:                                                           |
//|   - Compression persistence / ownership migration: when the      |
//|     losing side can't generate room, support/resistance migrates |
//|     to the 0.5-0.618 band of the expansion leg.                  |
//|   - Narrative lineage / chain vitality: are successive pullbacks |
//|     getting shallower (story strengthening) or deeper (fading).  |
//|                                                                  |
//|  The owning curve is the canonical M5 wave (se5); recursion depth |
//|  comes from the structure engine's recursive-transition count    |
//|  (se5_rec) and the compression index (se5_comp). Outputs are     |
//|  consumed by the trade manager to manage OPEN trades only - they  |
//|  never gate the Letra entries.                                   |
//+------------------------------------------------------------------+
#property strict

//================= CURVE-LIFE OUTPUTS =============================
double cl_life=50.0;
string cl_state="WEAKENING";       // ALIVE | WEAKENING | DEAD
int    cl_ownDir=0;                // owning curve direction
int    cl_counterDir=0;            // flip direction when DEAD
string cl_aliveTx="—";
string cl_cpState="NEUTRAL";       // PERSISTING | NEUTRAL | LEAKING
string cl_cpTrend="-> stable";
double cl_cpForce=0.0;
string cl_narrState="HOLDING";     // STRENGTHENING | HOLDING | WEAKENING
double cl_narrative=50.0;
double cl_chainVitality=50.0, cl_wholeChainLife=50.0;
string cl_chainScope="healthy";
double cl_mig50=PINE_NA, cl_mig618=PINE_NA;
double cl_parentThreat=PINE_NA, cl_htfRoomAtr=PINE_NA;
string cl_htfThreat="—";
bool   cl_progressing=false;

//--- internal persistent state
CRing  g_compHist;
int    g_narrDir=0;
double g_legX=PINE_NA, g_legPBdepth=0.0;
int    g_supVotes=0, g_degVotes=0;
double g_seqRetr[];
double g_lifeSeq[];

void CurveLife_Init()
  {
   g_compHist.Init(16);
   g_narrDir=0; g_legX=PINE_NA; g_legPBdepth=0.0;
   g_supVotes=0; g_degVotes=0;
   cl_narrative=50.0; cl_wholeChainLife=50.0;
   ArrayResize(g_seqRetr,0); ArrayResize(g_lifeSeq,0);
  }

void CL_PushCap(double &arr[],const double v,const int cap)
  {
   int n=ArraySize(arr); ArrayResize(arr,n+1); arr[n]=v;
   while(ArraySize(arr)>cap) ArrayRemove(arr,0,1);
  }

void CurveLife_Compute()
  {
   double cl=C_close(), hi=C_high(), lo=C_low();
   double atrv=IsNa(atr)?0.0:atr;

   //--- owner curve = canonical M5 wave
   int    ownDir = l0_dir;
   double ownOrig= se5_inv;
   double ownExt = (ownDir==1) ? se5_sh : (ownDir==-1) ? se5_sl : PINE_NA;
   cl_ownDir = ownDir;
   cl_counterDir = -ownDir;

   //--- compression persistence (read FROM the canonical compression)
   double cmpNow = se5_comp;
   g_compHist.Push(cmpNow);
   double cmp5 = g_compHist.Has(5) ? g_compHist.Get(5) : cmpNow;
   double cmpTighten = cmpNow - cmp5;
   double eRes = re_residualEnergyScore;
   int    treeDepth = (int)se5_rec;
   int    budget = co_expectedDepth;   // geometry-aware curve budget (Principle 4)
   bool   recComplete = (budget>0 && treeDepth>=budget);

   cl_cpForce = Clamp(cmpNow*0.50 + eRes*0.20 - treeDepth*12.0 + MathMax(0.0,cmpTighten)*0.8 + 8.0, 0.0, 100.0);
   cl_cpState = cl_cpForce>=60.0 ? "PERSISTING" : cl_cpForce<=35.0 ? "LEAKING" : "NEUTRAL";
   cl_cpTrend = cmpTighten>3.0 ? "tightening" : cmpTighten<-3.0 ? "broadening" : "stable";

   //--- progress guard: attacking the extreme / trend impulse = strength
   bool attacking = ownDir==1 ? (hi>=Nz(ownExt,hi)) : ownDir==-1 ? (lo<=Nz(ownExt,lo)) : false;
   bool trendImp  = (ownDir==1 && bullImpulse)||(ownDir==-1 && bearImpulse);
   cl_progressing = attacking||trendImp;

   //--- retrace depth from the curve's extreme
   double retrX = (IsNa(ownExt)||IsNa(ownOrig)||ownExt==ownOrig) ? 50.0 :
                  PineMin(MathAbs(ownExt-cl)/MathMax(MathAbs(ownExt-ownOrig),1e-10)*100.0, 100.0);

   //--- HTF parent threat (H4 zone)
   cl_parentThreat = ownDir==1 ? ((!IsNa(se240_ft)&&se240_ft>cl)?se240_ft:se240_sh) :
                     ownDir==-1 ? ((!IsNa(se240_fb)&&se240_fb<cl)?se240_fb:se240_sl) : PINE_NA;
   cl_htfRoomAtr = IsNa(cl_parentThreat) ? PINE_NA : MathAbs(cl_parentThreat-cl)/MathMax(atrv,1e-10);
   cl_htfThreat = IsNa(cl_htfRoomAtr) ? "—" : cl_htfRoomAtr>3.0 ? "CLEAR runway" : cl_htfRoomAtr>1.0 ? "APPROACHING" : "AT ZONE";

   //--- LIFE score
   cl_life = Clamp(
        cl_cpForce*0.45 + eRes*0.30 +
        (cmpTighten>0.0 ? 12.0 : 0.0) -
        ((recComplete && !cl_progressing) ? 25.0 : 0.0) -
        ((cl_cpState=="LEAKING" && !cl_progressing) ? 20.0 : 0.0) +
        (cl_progressing ? 28.0 : 0.0) +
        (retrX<25.0 ? 16.0 : retrX<45.0 ? 6.0 : retrX>75.0 ? -12.0 : 0.0) + 10.0, 0.0, 100.0);

   //--- ALIVE / WEAKENING / DEAD verdict
   if(ownDir==0)                                   { cl_state="WEAKENING"; cl_aliveTx="no curve - wait"; }
   else if(cl_htfThreat=="AT ZONE" && cl_life>=45) { cl_state="ALIVE"; cl_aliveTx="ALIVE - AT H4, VIGILANT"; }
   else if(cl_progressing && cl_life>=45)          { cl_state="ALIVE"; cl_aliveTx="ALIVE - ATTACKING EXTREME"; }
   else if(cl_life>=60.0)                          { cl_state="ALIVE"; cl_aliveTx="ALIVE - HOLD"; }
   else if(cl_life<=32.0)                          { cl_state="DEAD";  cl_aliveTx=(ownDir==1?"DEAD - FLIP SHORT":"DEAD - FLIP LONG"); }
   else                                            { cl_state="WEAKENING"; cl_aliveTx="WEAKENING - MANAGE"; }

   //--- migrated ownership band (0.5 / 0.618 of the owner leg)
   cl_mig50  = (IsNa(ownOrig)||IsNa(ownExt)) ? PINE_NA : ownExt + 0.5  *(ownOrig-ownExt);
   cl_mig618 = (IsNa(ownOrig)||IsNa(ownExt)) ? PINE_NA : ownExt + 0.618*(ownOrig-ownExt);

   //--- NARRATIVE LINEAGE - successive pullback depths
   if(ownDir!=g_narrDir)
     {
      g_narrDir=ownDir;
      g_legX = ownDir==1?hi:ownDir==-1?lo:PINE_NA;
      g_legPBdepth=0.0; cl_narrative=50.0; g_supVotes=0; g_degVotes=0;
      ArrayResize(g_seqRetr,0); ArrayResize(g_lifeSeq,0);
     }
   if(ownDir!=0 && !IsNa(ownOrig))
     {
      bool newLegX = ownDir==1 ? hi>Nz(g_legX,hi) : lo<Nz(g_legX,lo);
      if(newLegX)
        {
         if(g_legPBdepth>6.0)
           {
            bool sup = g_legPBdepth<=50.0 && cmpTighten>=-1.0;
            bool deg = g_legPBdepth>=62.0 || cmpTighten<-3.0;
            int  vote = sup?1:deg?-1:0;
            g_supVotes += (vote==1?1:0);
            g_degVotes += (vote==-1?1:0);
            cl_narrative = Clamp(cl_narrative + vote*12.0 + (cmpTighten>0.0?3.0:-3.0), 0.0, 100.0);
            CL_PushCap(g_seqRetr, g_legPBdepth, 5);
            CL_PushCap(g_lifeSeq, cl_life, 5);
           }
         g_legX = ownDir==1?hi:lo;
         g_legPBdepth=0.0;
        }
      else
        {
         double pbd = MathAbs(Nz(g_legX,cl)-ownOrig)>1e-9 ? MathAbs(Nz(g_legX,cl)-cl)/MathAbs(Nz(g_legX,cl)-ownOrig)*100.0 : 0.0;
         g_legPBdepth = MathMax(g_legPBdepth, pbd);
        }
     }
   cl_narrState = cl_narrative>=65.0 ? "STRENGTHENING" : cl_narrative<=35.0 ? "WEAKENING" : "HOLDING";

   //--- CHAIN VITALITY (is life decaying across successive curves?)
   cl_wholeChainLife = cl_wholeChainLife + 0.02*(cl_life-cl_wholeChainLife);
   int ls=ArraySize(g_lifeSeq);
   cl_chainVitality = ls>=2 ? Clamp(50.0+(g_lifeSeq[ls-1]-g_lifeSeq[0]), 0.0, 100.0) : cl_wholeChainLife;
   cl_chainScope = cl_life>=50.0 ? "healthy" :
                   cl_chainVitality>=50.0 ? "CURVE only - chain intact" :
                   cl_wholeChainLife>=45.0 ? "CHAIN weakening" : "WHOLE CHAIN decaying";
  }
//+------------------------------------------------------------------+
