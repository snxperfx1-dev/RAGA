//+------------------------------------------------------------------+
//|  BeliefEngine.mqh - SECTION 3: HTF Belief Engine + MTF bias      |
//|                     + SECTION 12I: M1 early-warning physics      |
//|                                                                  |
//|  f_htfBeliefs() is evaluated on tf1 (HTF bias 1) and tf2         |
//|  (HTF bias 2). Each returns a directional read plus expansion /  |
//|  decay / curvature / absorption / liquidity belief scores.       |
//|  htfBias1/2 latch on strong expansion and release on strong      |
//|  decay; htfAlign requires both biases to agree.                  |
//+------------------------------------------------------------------+
#property strict

//================= GLOBAL OUTPUTS =================================
int    dir_tf1=0, dir_tf2=0;
double expScr_tf1=0, expScr_tf2=0;
double decScr_tf1=0, decScr_tf2=0;
double curvScr_tf1=0, curvScr_tf2=0;
double abScr_tf1=0, abScr_tf2=0;
double liqScr_tf1=0, liqScr_tf2=0;

int    htfBias1=0, htfBias2=0;
int    htfAlign=0;

//--- M1 early warning (Section 12I); some are forward-referenced vars
bool   m1ExpansionWeak=false;
bool   m1ConvexityEmer=false;
bool   m1InductionEmer=false;
bool   m1LiquidityEmer=false;
bool   m1AbsorptionEmer=false;
int    m1WarningScore=0;
string m1Warning="CLEAR";

//==================================================================
//| CHtfBelief - f_htfBeliefs() per HTF                             |
//==================================================================
class CHtfBelief
  {
private:
   CRma              m_atr;
   CEma              m_velEma;
   CEma              m_csmEma;
   CRing             m_close;
   CRing             m_absdiff;
   double            m_velPrev, m_accPrev;
   bool              m_havePrev;
   double            m_prevClose;
public:
   int               outDir;
   double            outExp, outDec, outCurv, outAb, outLiq;
   datetime          lastOpen;

   void              Init()
     {
      m_atr.Init(cfg_atrLen);
      m_velEma.Init(3);
      m_csmEma.Init(3);
      m_close.Init(cfg_obLookback+4);
      m_absdiff.Init(cfg_obLookback+4);
      m_velPrev=0; m_accPrev=0; m_havePrev=false; m_prevClose=PINE_NA;
      outDir=0; outExp=0; outDec=0; outCurv=0; outAb=0; outLiq=0; lastOpen=0;
     }

   void              Update(const double o,const double h,const double l,const double c)
     {
      double tr = (!m_havePrev) ? (h-l) : MathMax(h-l, MathMax(MathAbs(h-m_prevClose),MathAbs(l-m_prevClose)));
      double _atr = m_atr.Update(tr);
      double dc   = m_havePrev ? (c-m_prevClose) : 0.0;
      double _vel = m_velEma.Update(dc);
      double _acc = _vel - m_velPrev;
      double _conv= _acc - m_accPrev;
      double _csm = m_csmEma.Update(_conv);
      double _convTh = (IsNa(_atr)?0.0:_atr)*cfg_convMult;

      m_close.Push(c);
      m_absdiff.Push(MathAbs(dc));
      double _eff=0.0;
      if(m_close.Has(cfg_obLookback))
        {
         double cO = m_close.Get(cfg_obLookback);
         double mv = MathAbs(c-cO);
         double ps = m_absdiff.Sum(cfg_obLookback);
         _eff = (ps>0.0)? mv/ps : 0.0;
        }
      double atrSafe = MathMax(IsNa(_atr)?0.0:_atr,1e-10);
      double _disp = (h-l)/atrSafe;
      double effT=cfg_effThresh, dispT=cfg_dispThresh;
      double convThSafe = MathMax(_convTh,1e-10);

      double _expScore = PineMin(_eff/MathMax(effT,1e-10)*50.0 + _disp/MathMax(dispT,1e-10)*50.0, 100.0);
      double _decayScr = (MathAbs(_acc) < MathAbs(m_accPrev)*0.8) ? PineMin(MathAbs(_conv)/convThSafe*50.0,100.0) : 0.0;
      double _curvScr  = PineMin(MathAbs(_csm)/convThSafe*50.0,100.0);
      double _abScr    = (_eff<effT*0.7 && MathAbs(_vel)<MathAbs(m_velPrev)*0.6) ? 60.0+_curvScr*0.4 : _curvScr*0.3;
      double _liqScr   = (MathAbs(_csm)>_convTh*1.5 && _disp>dispT) ? PineMin(_curvScr*1.2,100.0) : _curvScr*0.5;

      bool _bullImp = (_eff>effT)&&(_vel>m_velPrev)&&(_acc>0)&&(c>o)&&(_disp>dispT);
      bool _bearImp = (_eff>effT)&&(_vel<m_velPrev)&&(_acc<0)&&(c<o)&&(_disp>dispT);
      int  _dir = _bullImp?1:_bearImp?-1:0;

      outDir=_dir; outExp=_expScore; outDec=_decayScr; outCurv=_curvScr; outAb=_abScr; outLiq=_liqScr;

      m_velPrev=_vel; m_accPrev=_acc; m_prevClose=c; m_havePrev=true;
     }
  };

//==================================================================
//| CM1Phys - f_m1Physics() early-warning on M1                     |
//==================================================================
class CM1Phys
  {
private:
   CRma              m_atr;
   CEma              m_velEma;
   CRing             m_close;
   CRing             m_absdiff;
   double            m_velPrev, m_accPrev;
   bool              m_havePrev;
   double            m_prevClose;
public:
   bool              oExpWeak,oConvEmer,oIndEmer,oLiqEmer,oAbsEmer;
   datetime          lastOpen;

   void              Init()
     {
      m_atr.Init(cfg_atrLen);
      m_velEma.Init(3);
      m_close.Init(cfg_effLen+4);
      m_absdiff.Init(cfg_effLen+4);
      m_velPrev=0; m_accPrev=0; m_havePrev=false; m_prevClose=PINE_NA;
      oExpWeak=false;oConvEmer=false;oIndEmer=false;oLiqEmer=false;oAbsEmer=false;lastOpen=0;
     }

   void              Update(const double o,const double h,const double l,const double c)
     {
      double tr = (!m_havePrev)?(h-l):MathMax(h-l,MathMax(MathAbs(h-m_prevClose),MathAbs(l-m_prevClose)));
      double _atr=m_atr.Update(tr);
      double dc = m_havePrev?(c-m_prevClose):0.0;
      double _v = m_velEma.Update(dc);
      double _a = _v - m_velPrev;
      double _cv= _a - m_accPrev;
      m_close.Push(c); m_absdiff.Push(MathAbs(dc));
      double _e=0.0;
      if(m_close.Has(cfg_effLen))
        {
         double cO=m_close.Get(cfg_effLen);
         double mvv=MathAbs(c-cO);
         double ps=m_absdiff.Sum(cfg_effLen);
         _e=(ps>0.0)?mvv/ps:0.0;
        }
      double atrSafe=MathMax(IsNa(_atr)?0.0:_atr,1e-10);
      double _d=(h-l)/atrSafe;
      double atrv = IsNa(_atr)?0.0:_atr;
      bool _mD = MathAbs(_a) < MathAbs(m_accPrev)*0.8;
      oExpWeak = (_e<cfg_effThresh*0.7) && _mD;
      oConvEmer= (MathAbs(_cv)>atrv*cfg_convMult*1.5) && _mD;
      oIndEmer = (_e>cfg_effThresh) && (_a<0) && (_v>0);
      oLiqEmer = (_d>cfg_dispThresh*1.2) && _mD;
      oAbsEmer = (_e<cfg_effThresh*0.5) && (_d<cfg_dispThresh*0.6);
      m_velPrev=_v; m_accPrev=_a; m_prevClose=c; m_havePrev=true;
     }
  };

CHtfBelief g_b1, g_b2;
CM1Phys    g_m1;

//==================================================================
void Belief_Init()
  {
   g_b1.Init();
   g_b2.Init();
   g_m1.Init();
   dir_tf1=0; dir_tf2=0; htfBias1=0; htfBias2=0; htfAlign=0;
  }

//--- feed one engine over its TF's pending closed bars
void Belief_FeedOne(CHtfBelief &eng,const ENUM_TIMEFRAMES tf,const datetime moment)
  {
   int shifts[];
   int n=Ctx_PendingBars(tf, eng.lastOpen, moment, shifts);
   for(int i=0;i<n;i++)
     {
      int s=shifts[i];
      double o=iOpen(_Symbol,tf,s),h=iHigh(_Symbol,tf,s),l=iLow(_Symbol,tf,s),c=iClose(_Symbol,tf,s);
      if(o==0&&h==0&&l==0&&c==0) continue;
      eng.Update(o,h,l,c);
      eng.lastOpen=iTime(_Symbol,tf,s);
     }
  }

void Belief_FeedM1(const datetime moment)
  {
   int shifts[];
   int n=Ctx_PendingBars(PERIOD_M1, g_m1.lastOpen, moment, shifts);
   for(int i=0;i<n;i++)
     {
      int s=shifts[i];
      double o=iOpen(_Symbol,PERIOD_M1,s),h=iHigh(_Symbol,PERIOD_M1,s),l=iLow(_Symbol,PERIOD_M1,s),c=iClose(_Symbol,PERIOD_M1,s);
      if(o==0&&h==0&&l==0&&c==0) continue;
      g_m1.Update(o,h,l,c);
      g_m1.lastOpen=iTime(_Symbol,PERIOD_M1,s);
     }
  }

void Belief_Feed(const datetime moment)
  {
   Belief_FeedOne(g_b1, cfg_tf1, moment);
   Belief_FeedOne(g_b2, cfg_tf2, moment);
   Belief_FeedM1(moment);
  }

//==================================================================
//  Chart-bar derivation: publish scores, latch biases, m1 warning
//==================================================================
void Belief_DeriveLive()
  {
   dir_tf1=g_b1.outDir; dir_tf2=g_b2.outDir;
   expScr_tf1=g_b1.outExp; expScr_tf2=g_b2.outExp;
   decScr_tf1=g_b1.outDec; decScr_tf2=g_b2.outDec;
   curvScr_tf1=g_b1.outCurv; curvScr_tf2=g_b2.outCurv;
   abScr_tf1=g_b1.outAb; abScr_tf2=g_b2.outAb;
   liqScr_tf1=g_b1.outLiq; liqScr_tf2=g_b2.outLiq;

   //--- latch (Section 3)
   if(expScr_tf1>60 && dir_tf1!=0) htfBias1=dir_tf1;
   if(expScr_tf2>60 && dir_tf2!=0) htfBias2=dir_tf2;
   if(decScr_tf1>70 && dir_tf1==htfBias1) htfBias1=0;
   if(decScr_tf2>70 && dir_tf2==htfBias2) htfBias2=0;

   htfAlign = (htfBias1==1 && htfBias2==1) ? 1 :
              (htfBias1==-1 && htfBias2==-1) ? -1 : 0;

   //--- M1 early warning aggregation
   m1ExpansionWeak = g_m1.oExpWeak;
   m1ConvexityEmer = g_m1.oConvEmer;
   m1InductionEmer = g_m1.oIndEmer;
   m1LiquidityEmer = g_m1.oLiqEmer;
   m1AbsorptionEmer= g_m1.oAbsEmer;
   m1WarningScore  = (m1ExpansionWeak?1:0)+(m1ConvexityEmer?1:0)+(m1InductionEmer?1:0)+(m1LiquidityEmer?1:0)+(m1AbsorptionEmer?1:0);
   m1Warning = m1WarningScore>=4 ? "CRITICAL" : m1WarningScore>=3 ? "HIGH" : m1WarningScore>=2 ? "MODERATE" : m1WarningScore>=1 ? "LOW" : "CLEAR";
  }
//+------------------------------------------------------------------+
