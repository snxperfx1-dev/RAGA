//+------------------------------------------------------------------+
//|  StructureEngine.mqh - the fixed-timeframe structure engine      |
//|                                                                  |
//|  Faithful port of f_se(): a self-contained structure state       |
//|  machine that computes (using ONLY its own timeframe series):    |
//|    physics, swings, pivot memory, BOS/CHoCH, impulse, direction  |
//|    + Point4 / invalidation / target, a monotonic lifecycle phase |
//|    state and a live phase code, plus FRZ / waveProgress /         |
//|    convexity-maturity / model-fit.                               |
//|                                                                  |
//|  Six instances run on M1/M3/M5/M15/H1/H4. The live direction of  |
//|  each layer is recomputed against the chart close (origin-based) |
//|  exactly as f_waveDirByOrigin() does, then aggregated into the   |
//|  fractal stack and Engine 1A phase authority.                    |
//+------------------------------------------------------------------+
#property strict

//================= ENGINE-1A / LAYER GLOBALS ======================
int    m1_dir=0, l3_dir=0, l0_dir=0, l1_dir=0, l2_dir=0, l4_dir=0;
double l0_p4High=PINE_NA, l0_p4Low=PINE_NA, l0_inv=PINE_NA, se5_tgt=PINE_NA;
double se5_mf=0.0, se5_wp=0.0;
string l0_phaseCanon="Point 4 Origin";
string ie1a_currentPhase="Point 4 Origin";
string ie1a_hypFamily="EXPANSION";
double ie1a_phaseConfidence=20.0;
bool   ie1a_isExpSide=true;
int    fractalStackDir=0;
double fractalStackScore=0.0;
double fractalCtxScore=0.0;
int    liveWaveDir=0;
int    liveHtfAlign=0;

//==================================================================
//  phase code -> canonical lifecycle string (f_phaseStr)
//==================================================================
string PhaseStr(const int c)
  {
   switch(c)
     {
      case 1:  return "Expansion";
      case 2:  return "Expansion Pre-Convexity";
      case 3:  return "Expansion Induction";
      case 4:  return "Expansion Liquidity";
      case 5:  return "New High";
      case 6:  return "New Low";
      case 7:  return "Absorption";
      case 8:  return "Retracement";
      case 9:  return "Retracement Pre-Convexity";
      case 10: return "Retracement Induction";
      case 11: return "Retracement Liquidity";
      case 12: return "Demand Return";
      case 13: return "Supply Return";
      default: return "Point 4 Origin";
     }
  }

//  canonical phase -> hypothesis family (ie1a_hypFamily)
string HypFamily(const string ph)
  {
   if(ph=="Expansion") return "EXPANSION";
   if(ph=="Expansion Pre-Convexity" || ph=="Expansion Induction" || ph=="Expansion Liquidity") return "CONVEXITY FORMING";
   if(ph=="New High" || ph=="New Low") return "CREATION FORMING";
   if(ph=="Absorption") return "ABSORPTION";
   if(ph=="Retracement" || ph=="Retracement Pre-Convexity" || ph=="Retracement Induction" || ph=="Retracement Liquidity") return "RETRACEMENT";
   if(ph=="Demand Return" || ph=="Supply Return") return "DEMAND/SUPPLY RETURN";
   return "EXPANSION";
  }

bool PhaseIsExpSide(const string ph)
  {
   return(ph=="Expansion" || ph=="Expansion Pre-Convexity" || ph=="Expansion Induction" ||
          ph=="Expansion Liquidity" || ph=="New High" || ph=="New Low");
  }

//==================================================================
//| CStructEngine - one f_se instance                              |
//==================================================================
class CStructEngine
  {
private:
   //--- physics state
   CRma   m_atr;
   CEma   m_velEma, m_csmEma;
   CRing  m_close, m_absdiff;
   double m_velPrev, m_accPrev;
   bool   m_havePrev;
   double m_prevClose;
   //--- pivot detection rings
   CRing  m_hi, m_lo;
   //--- swing state
   double m_curSH, m_curSL, m_prSH, m_prSL;
   //--- pivot memory
   double m_lastP, m_prevP;
   int    m_lastD, m_prevD;
   //--- direction / point4 / invalidation / target
   int    m_dir;
   double m_ft, m_fb, m_p4h, m_p4l, m_inv, m_tgt, m_cycH, m_cycL;
   //--- lifecycle
   bool   m_bos1, m_bos2;
   double m_protSw, m_protSw2, m_indOrig, m_indExt;
   bool   m_indBrk;
   int    m_lastDirSeen;
   int    m_phaseState;
public:
   //--- outputs (se*_*)
   int    oDir, oPh, oBos, oCh;
   double oSH, oSL, oPSH, oPSL, oP4h, oP4l, oInv, oTgt, oFt, oFb, oFs, oWp, oCm, oMf;
   datetime lastOpen;

   void   Init()
     {
      m_atr.Init(cfg_atrLen);
      m_velEma.Init(3);
      m_csmEma.Init(3);
      m_close.Init(cfg_effLen+4);
      m_absdiff.Init(cfg_effLen+4);
      m_velPrev=0; m_accPrev=0; m_havePrev=false; m_prevClose=PINE_NA;
      int pcap = 2*cfg_pivotLen+4;
      m_hi.Init(pcap); m_lo.Init(pcap);
      m_curSH=PINE_NA; m_curSL=PINE_NA; m_prSH=PINE_NA; m_prSL=PINE_NA;
      m_lastP=PINE_NA; m_prevP=PINE_NA; m_lastD=0; m_prevD=0;
      m_dir=0; m_ft=PINE_NA; m_fb=PINE_NA; m_p4h=PINE_NA; m_p4l=PINE_NA;
      m_inv=PINE_NA; m_tgt=PINE_NA; m_cycH=PINE_NA; m_cycL=PINE_NA;
      m_bos1=false; m_bos2=false; m_protSw=PINE_NA; m_protSw2=PINE_NA;
      m_indOrig=PINE_NA; m_indExt=PINE_NA; m_indBrk=false; m_lastDirSeen=0; m_phaseState=0;
      oDir=0; oPh=0; oBos=0; oCh=0;
      oSH=PINE_NA; oSL=PINE_NA; oPSH=PINE_NA; oPSL=PINE_NA;
      oP4h=PINE_NA; oP4l=PINE_NA; oInv=PINE_NA; oTgt=PINE_NA; oFt=PINE_NA; oFb=PINE_NA;
      oFs=0; oWp=0; oCm=0; oMf=0; lastOpen=0;
     }

   void   Update(const double o,const double h,const double l,const double c)
     {
      double effT=cfg_effThresh, dispT=cfg_dispThresh, convM=cfg_convMult, impM=cfg_impulseAtrMult, chBuf=cfg_chochBufferATR;

      //---- PHYSICS (this tf) ----
      double tr = (!m_havePrev)?(h-l):MathMax(h-l,MathMax(MathAbs(h-m_prevClose),MathAbs(l-m_prevClose)));
      double _atr=m_atr.Update(tr);
      double atrv=IsNa(_atr)?0.0:_atr;
      double dc = m_havePrev?(c-m_prevClose):0.0;
      double _vel=m_velEma.Update(dc);
      double _acc=_vel-m_velPrev;
      double _conv=_acc-m_accPrev;
      double _csm=m_csmEma.Update(_conv);
      m_close.Push(c); m_absdiff.Push(MathAbs(dc));
      double _eff=0.0;
      if(m_close.Has(cfg_effLen))
        {
         double cO=m_close.Get(cfg_effLen);
         double ps=m_absdiff.Sum(cfg_effLen);
         _eff=(ps>0.0)?MathAbs(c-cO)/ps:0.0;
        }
      double _disp=(h-l)/MathMax(atrv,1e-10);
      bool _bullImp=(_eff>effT)&&(_vel>m_velPrev)&&(_acc>0)&&(c>o)&&(_disp>dispT);
      bool _bearImp=(_eff>effT)&&(_vel<m_velPrev)&&(_acc<0)&&(c<o)&&(_disp>dispT);
      bool _bullDec=(MathAbs(_acc)<MathAbs(m_accPrev)*0.8)&&(_vel>0);
      bool _bearDec=(MathAbs(_acc)<MathAbs(m_accPrev)*0.8)&&(_vel<0);
      double velPrevAbs=MathAbs(m_velPrev);

      //---- SWINGS ----
      m_hi.Push(h); m_lo.Push(l);
      double _pH=PivotHigh(m_hi, cfg_pivotLen);
      double _pL=PivotLow (m_lo, cfg_pivotLen);
      if(!IsNa(_pH)){ m_prSH = IsNa(m_curSH)?_pH:m_curSH; m_curSH=_pH; }
      if(!IsNa(_pL)){ m_prSL = IsNa(m_curSL)?_pL:m_curSL; m_curSL=_pL; }

      //---- PIVOT MEMORY ----
      double _eP=PINE_NA; int _eD=0;
      if(!IsNa(_pH)){ _eP=_pH; _eD=1; }
      else if(!IsNa(_pL)){ _eP=_pL; _eD=-1; }
      if(_eD!=0){ m_prevP=m_lastP; m_prevD=m_lastD; m_lastP=_eP; m_lastD=_eD; }

      //---- BOS / CHoCH ----
      bool _bullBOS=(!IsNa(m_prSH))&&(c>m_prSH);
      bool _bearBOS=(!IsNa(m_prSL))&&(c<m_prSL);
      bool _bullCH =(!IsNa(m_prSH))&&(c>m_prSH+atrv*chBuf);
      bool _bearCH =(!IsNa(m_prSL))&&(c<m_prSL-atrv*chBuf);

      //---- IMPULSE ----
      bool _eLong =(!IsNa(_pH))&&(m_prevD==-1)&&(!IsNa(m_prevP))&&((_pH-m_prevP)>atrv*impM);
      bool _eShort=(!IsNa(_pL))&&(m_prevD==1 )&&(!IsNa(m_prevP))&&((m_prevP-_pL)>atrv*impM);

      //---- DIRECTION / POINT4 / INVALIDATION / TARGET ----
      bool _hasCtx=(m_dir!=0)&&(!IsNa(m_ft));
      bool _flipDn=(m_dir==1)&&_bearCH;
      bool _flipUp=(m_dir==-1)&&_bullCH;
      bool _isRev =(_eLong&&m_dir==-1)||(_eShort&&m_dir==1)||_flipUp||_flipDn;
      bool _spawn =(_eLong||_eShort||_flipUp||_flipDn)&&(!_hasCtx||_isRev);
      if(_spawn)
        {
         int _nd=_eLong?1:_eShort?-1:_flipUp?1:-1;
         double _obT=(_nd==1)?m_lastP:m_prevP;
         double _obB=(_nd==1)?m_prevP:m_lastP;
         m_dir=_nd; m_ft=_obT; m_fb=_obB; m_p4h=_obT; m_p4l=_obB; m_cycH=h; m_cycL=l;
         m_inv=(_nd==1)?_obB:_obT;
         double _rng=(!IsNa(m_prSH)&&!IsNa(m_prSL))?MathAbs(m_prSH-m_prSL):atrv*5.0;
         m_tgt=(_nd==1)?Nz(_obT,c)+_rng:Nz(_obB,c)-_rng;
        }
      if(m_dir==1)  m_cycH=IsNa(m_cycH)?h:MathMax(m_cycH,h);
      if(m_dir==-1) m_cycL=IsNa(m_cycL)?l:MathMin(m_cycL,l);
      int _bosOut=_bullBOS?1:_bearBOS?-1:0;
      int _chOut =_bullCH ?1:_bearCH ?-1:0;

      //---- LIFECYCLE ----
      bool _reset=(m_dir!=m_lastDirSeen);
      m_lastDirSeen=m_dir;
      if(_reset){ m_bos1=false; m_bos2=false; m_protSw=PINE_NA; m_protSw2=PINE_NA; m_indOrig=PINE_NA; m_indExt=PINE_NA; m_indBrk=false; }
      if(m_dir==1 && !IsNa(_pL)){ m_protSw2=m_protSw; m_protSw=_pL; }
      if(m_dir==-1 && !IsNa(_pH)){ m_protSw2=m_protSw; m_protSw=_pH; }
      bool _oppBOS=(m_dir==1 && !IsNa(m_protSw) && c<m_protSw)||(m_dir==-1 && !IsNa(m_protSw) && c>m_protSw);
      if(!m_bos1 && _oppBOS){ m_bos1=true; m_indOrig=(m_dir==1)?Nz(m_cycH,h):Nz(m_cycL,l); }
      if(m_bos1 && !m_bos2 && _oppBOS && !IsNa(m_protSw2) && (m_dir==1?c<m_protSw2:c>m_protSw2)) m_bos2=true;
      if(m_bos1 && m_dir==1)  m_indExt=IsNa(m_indExt)?c:MathMin(m_indExt,c);
      if(m_bos1 && m_dir==-1) m_indExt=IsNa(m_indExt)?c:MathMax(m_indExt,c);
      if(m_bos2 && !IsNa(m_indOrig))
        {
         if(m_dir==1 && c>m_indOrig) m_indBrk=true;
         if(m_dir==-1 && c<m_indOrig) m_indBrk=true;
        }

      //---- SCORES ----
      double _convScore=PineMin(MathAbs(_csm)/MathMax(atrv*convM,1e-10)*50.0,100.0);
      double _expScore =PineMin(_eff/MathMax(effT,1e-10)*50.0+_disp/MathMax(dispT,1e-10)*50.0,100.0);
      double _absScore =(_eff<effT*0.7 && MathAbs(_vel)<velPrevAbs*0.6) ? 60.0+_convScore*0.4 : _convScore*0.3;
      bool _momExpStrong=(_eff>effT*0.75)&&(m_dir==1?_vel>0:_vel<0);
      bool _momDecaying =(m_dir==1)?_bullDec:_bearDec;
      bool _momCounter  =(m_dir==1)?_bearImp:_bullImp;
      bool _momExhaust  =(_eff<effT*0.65)&&(_absScore>40.0);
      bool _physConvexDevel=_convScore>35.0;
      bool _physTransfer   =_convScore>48.0||_absScore>40.0;
      bool _physCapacityLow=_absScore>45.0||_eff<effT*0.6;

      //---- PHASE STATE (monotonic) ----
      if(_reset) m_phaseState=0;
      if(m_dir!=0)
        {
         bool _expanding=_momExpStrong||_eLong||_eShort||(m_dir==1?_bullImp:_bearImp);
         if(m_phaseState<1 && _expanding && !_physTransfer && !_physCapacityLow) m_phaseState=1;
         if(m_phaseState<2 && m_bos1 && _momDecaying && _physConvexDevel) m_phaseState=2;
         if(m_phaseState<3 && m_bos1 && _momCounter && _physTransfer) m_phaseState=3;
         if(m_phaseState<4 && m_bos2 && (_momDecaying||_momCounter) && _physTransfer) m_phaseState=4;
         if(m_phaseState<5 && m_indBrk && _momExpStrong && !_physCapacityLow) m_phaseState=5;
         if(m_phaseState>=5 && _momExhaust && _physCapacityLow) m_phaseState=7;
         if(m_phaseState>=5 && _momCounter && !_momExhaust && _physTransfer) m_phaseState=8;
        }
      int _phase=m_phaseState;
      if(m_dir!=0)
        {
         if(_momExhaust && _physCapacityLow) _phase=7;
         else if(_momCounter && _physTransfer)
            _phase = (m_phaseState>=5) ? (_convScore>40.0?10:_momDecaying?9:8) : (m_bos2?4:3);
         else if(_momExpStrong)
            _phase = (m_phaseState>=5)?m_phaseState:((m_bos2&&_physTransfer)?4:((m_bos1&&_physConvexDevel)?2:1));
         else if(_momDecaying)
            _phase = (m_phaseState>=5)?m_phaseState:4;
         else if(m_phaseState==0) _phase=1;
         else _phase=m_phaseState;
        }
      if(_phase==5 && m_dir==-1) _phase=6;

      double _wp = (m_phaseState==0)?10.0:(m_phaseState==1)?25.0:(m_phaseState==2)?40.0:(m_phaseState==3)?55.0:(m_phaseState==4)?68.0:(m_phaseState==5)?80.0:(m_phaseState==7)?92.0:85.0;
      double _cm = PineMin(_convScore,100.0);
      double _mf = PineMin(MathMax(_expScore,MathMax(_absScore,_convScore))*0.70+(m_dir!=0?30.0:0.0),100.0);
      double _frzS=PineMin((_eLong||_eShort?50.0:0.0)+_expScore*0.30+_convScore*0.20,100.0);
      int _dirLabel = (!IsNa(m_inv)) ? (c>m_inv?1:(c<m_inv?-1:m_dir)) : m_dir;

      //---- publish outputs ----
      oDir=_dirLabel; oPh=_phase; oSH=m_curSH; oSL=m_curSL; oPSH=m_prSH; oPSL=m_prSL;
      oBos=_bosOut; oCh=_chOut; oP4h=m_p4h; oP4l=m_p4l; oInv=m_inv; oTgt=m_tgt;
      oFt=m_ft; oFb=m_fb; oFs=_frzS; oWp=_wp; oCm=_cm; oMf=_mf;

      //---- commit physics state ----
      m_velPrev=_vel; m_accPrev=_acc; m_prevClose=c; m_havePrev=true;
     }
  };

CStructEngine g_se1, g_se3, g_se5, g_se15, g_se60, g_se240;

//==================================================================
void Struct_InitAll()
  {
   g_se1.Init(); g_se3.Init(); g_se5.Init(); g_se15.Init(); g_se60.Init(); g_se240.Init();
  }

void Struct_FeedEngine(CStructEngine &eng,const ENUM_TIMEFRAMES tf,const datetime moment)
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

void Struct_FeedAll(const datetime moment)
  {
   Struct_FeedEngine(g_se1,  PERIOD_M1,  moment);
   Struct_FeedEngine(g_se3,  PERIOD_M3,  moment);
   Struct_FeedEngine(g_se5,  PERIOD_M5,  moment);
   Struct_FeedEngine(g_se15, PERIOD_M15, moment);
   Struct_FeedEngine(g_se60, PERIOD_H1,  moment);
   Struct_FeedEngine(g_se240,PERIOD_H4,  moment);
  }

//==================================================================
//  f_waveDirByOrigin against the live chart close
//==================================================================
int WaveDirByOrigin(const double origin,const int fallback)
  {
   double cl=C_close();
   if(IsNa(origin) || IsNa(cl)) return fallback;
   if(cl>origin) return 1;
   if(cl<origin) return -1;
   return fallback;
  }

//==================================================================
//  Live derivation: layer dirs, fractal stack, Engine 1A
//==================================================================
void Struct_DeriveLive()
  {
   m1_dir = WaveDirByOrigin(g_se1.oInv,   g_se1.oDir);
   l3_dir = WaveDirByOrigin(g_se3.oInv,   g_se3.oDir);
   l0_dir = WaveDirByOrigin(g_se5.oInv,   g_se5.oDir);
   l1_dir = WaveDirByOrigin(g_se15.oInv,  g_se15.oDir);
   l2_dir = WaveDirByOrigin(g_se60.oInv,  g_se60.oDir);
   l4_dir = WaveDirByOrigin(g_se240.oInv, g_se240.oDir);

   l0_p4High = g_se5.oP4h;
   l0_p4Low  = g_se5.oP4l;
   l0_inv    = g_se5.oInv;
   se5_tgt   = g_se5.oTgt;
   se5_mf    = g_se5.oMf;
   se5_wp    = g_se5.oWp;

   l0_phaseCanon = PhaseStr(g_se5.oPh);

   //--- fractal stack
   int sb = (m1_dir==1?1:0)+(l3_dir==1?1:0)+(l0_dir==1?1:0)+(l1_dir==1?1:0)+(l2_dir==1?1:0)+(l4_dir==1?1:0);
   int sr = (m1_dir==-1?1:0)+(l3_dir==-1?1:0)+(l0_dir==-1?1:0)+(l1_dir==-1?1:0)+(l2_dir==-1?1:0)+(l4_dir==-1?1:0);
   fractalStackDir   = sb>sr ? 1 : (sr>sb ? -1 : 0);
   fractalStackScore = (double)MathMax(sb,sr)/6.0*100.0;

   fractalCtxScore = PineMin(
        (l4_dir==fractalStackDir && fractalStackDir!=0 ? 30.0:0.0)+
        (l2_dir==fractalStackDir && fractalStackDir!=0 ? 26.0:0.0)+
        (l1_dir==fractalStackDir && fractalStackDir!=0 ? 20.0:0.0)+
        (l0_dir==fractalStackDir && fractalStackDir!=0 ? 14.0:0.0)+
        (l3_dir==fractalStackDir && fractalStackDir!=0 ?  6.0:0.0)+
        (m1_dir==fractalStackDir && fractalStackDir!=0 ?  4.0:0.0), 100.0);

   liveWaveDir  = l0_dir;
   liveHtfAlign = (l2_dir!=0 && l2_dir==l4_dir) ? l2_dir : 0;

   //--- Engine 1A
   ie1a_currentPhase   = l0_phaseCanon;
   ie1a_phaseConfidence= Clamp(fractalCtxScore*0.50 + se5_mf*0.30 + se5_wp*0.20, 20.0, 100.0);
   ie1a_hypFamily      = HypFamily(ie1a_currentPhase);
   ie1a_isExpSide      = PhaseIsExpSide(ie1a_currentPhase);
  }
//+------------------------------------------------------------------+
