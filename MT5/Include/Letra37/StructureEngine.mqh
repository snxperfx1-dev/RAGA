//+------------------------------------------------------------------+
//|  StructureEngine.mqh - the fixed-timeframe structure engine      |
//|                       (V60 14-PHASE upgrade)                     |
//|                                                                  |
//|  Port of f_se(): a self-contained structure state machine that   |
//|  computes (using ONLY its own timeframe series): physics,        |
//|  swings, pivot memory, BOS/CHoCH, impulse, direction + Point4 /  |
//|  invalidation / target, and the V60 14-phase lifecycle driven    |
//|  by a COMPRESSION INDEX, RECURSIVE-TRANSITION counting and       |
//|  DOMINANCE TRANSFER. It models how a move dies and hands off:    |
//|    Expansion -> Pre-Convexity -> Induction -> Liquidity ->       |
//|    New High/Low -> Transition -> Retracement -> HTF Flip Zone -> |
//|    Induction -> Liquidation -> Terminal Curve -> Return.         |
//|                                                                  |
//|  DIR-FIX: the order block is ordered by ACTUAL price (hi/lo),    |
//|  and invalidation is pinned to the protective extreme (zone low  |
//|  for longs, zone high for shorts) so a flip/CHoCH spawn can no    |
//|  longer invert the wave-direction stack.                         |
//|                                                                  |
//|  Six instances run on the adaptive timeframe ladder. The live    |
//|  direction of each layer is recomputed against the chart close   |
//|  (origin-based), then aggregated into the fractal stack and      |
//|  Engine 1A phase authority.                                      |
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

//--- V60 extras + per-rung exports (consumed by CurveLife / TimeIntel / Trade)
double se5_comp=0.0, se5_rec=0.0, se5_dom=0.0;
double se5_inv=PINE_NA, se5_sh=PINE_NA, se5_sl=PINE_NA, se5_ft=PINE_NA, se5_fb=PINE_NA;
double se15_tgt=PINE_NA;
double se60_inv=PINE_NA, se60_sh=PINE_NA, se60_sl=PINE_NA, se60_ft=PINE_NA, se60_fb=PINE_NA, se60_tgt=PINE_NA, se60_wp=0.0, se60_comp=0.0;
double se240_inv=PINE_NA, se240_sh=PINE_NA, se240_sl=PINE_NA, se240_ft=PINE_NA, se240_fb=PINE_NA, se240_tgt=PINE_NA, se240_wp=0.0, se240_comp=0.0;
int    se60_phCode=0, se240_phCode=0;

//--- full per-rung curve state (for the multi-timeframe ownership engine)
double se1_wp=0.0,  se1_comp=0.0,  se1_rec=0.0,  se1_dom=0.0;
double se3_wp=0.0,  se3_comp=0.0,  se3_rec=0.0,  se3_dom=0.0;
double se15_wp=0.0, se15_comp=0.0, se15_rec=0.0, se15_dom=0.0;
double se60_rec=0.0, se60_dom=0.0;
double se240_rec=0.0, se240_dom=0.0;

//==================================================================
//  phase code -> canonical lifecycle string (V60 14-phase)
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
      case 7:  return "Transition";
      case 8:  return "Retracement";
      case 9:  return "HTF Flip Zone";
      case 10: return "Induction";
      case 11: return "Liquidation";
      case 12: return "Terminal Curve";
      case 13: return "Demand Return";
      case 14: return "Supply Return";
      default: return "Point 4 Origin";
     }
  }

//  canonical phase -> hypothesis family (ie1a_hypFamily)
//  Transition maps to the ABSORPTION family (the move dying / handing off);
//  HTF Flip Zone / Induction / Liquidation / Terminal Curve are the retracement
//  family (counter-trend delivery into the zone).
string HypFamily(const string ph)
  {
   if(ph=="Expansion") return "EXPANSION";
   if(ph=="Expansion Pre-Convexity" || ph=="Expansion Induction" || ph=="Expansion Liquidity") return "CONVEXITY FORMING";
   if(ph=="New High" || ph=="New Low") return "CREATION FORMING";
   if(ph=="Transition") return "ABSORPTION";
   if(ph=="Retracement" || ph=="HTF Flip Zone" || ph=="Induction" || ph=="Liquidation" || ph=="Terminal Curve") return "RETRACEMENT";
   if(ph=="Demand Return" || ph=="Supply Return") return "DEMAND/SUPPLY RETURN";
   return "EXPANSION";
  }

bool PhaseIsExpSide(const string ph)
  {
   return(ph=="Expansion" || ph=="Expansion Pre-Convexity" || ph=="Expansion Induction" ||
          ph=="Expansion Liquidity" || ph=="New High" || ph=="New Low");
  }

//  short phase-family label (multi-timeframe panels / curve map)
string PhaseFamS(const string p)
  {
   if(StringFind(p,"Transition")>=0)   return "Transition";
   if(StringFind(p,"Terminal")>=0)     return "Terminal";
   if(StringFind(p,"Liquidation")>=0)  return "Liquidation";
   if(StringFind(p,"HTF Flip")>=0)     return "Flip Zone";
   if(StringFind(p,"Induction")>=0 && StringFind(p,"Expansion")<0) return "Induction";
   if(StringFind(p,"Pre-Convexity")>=0) return "Pre-Conv";
   if(StringFind(p,"Expansion Induction")>=0) return "Induction";
   if(StringFind(p,"Liquidity")>=0)    return "Liquidity";
   if(StringFind(p,"New High")>=0 || StringFind(p,"New Low")>=0) return "Creation";
   if(StringFind(p,"Return")>=0)       return "Return";
   if(StringFind(p,"Retracement")>=0)  return "Retracement";
   return "Expansion";
  }

//==================================================================
//| CStructEngine - one f_se instance (V60 14-phase)               |
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
   int    m_pst;            // 0..13 single-latch phase state
   //--- recursive transition
   int    m_recBrk;
   bool   m_recArm;
public:
   //--- outputs (se*_*)
   int    oDir, oPh, oBos, oCh, oRec;
   double oSH, oSL, oPSH, oPSL, oP4h, oP4l, oInv, oTgt, oFt, oFb, oFs, oWp, oCm, oMf, oComp, oDom;
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
      m_indOrig=PINE_NA; m_indExt=PINE_NA; m_indBrk=false; m_lastDirSeen=0; m_pst=0;
      m_recBrk=0; m_recArm=true;
      oDir=0; oPh=0; oBos=0; oCh=0; oRec=0;
      oSH=PINE_NA; oSL=PINE_NA; oPSH=PINE_NA; oPSL=PINE_NA;
      oP4h=PINE_NA; oP4l=PINE_NA; oInv=PINE_NA; oTgt=PINE_NA; oFt=PINE_NA; oFb=PINE_NA;
      oFs=0; oWp=0; oCm=0; oMf=0; oComp=0; oDom=0; lastOpen=0;
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

      //---- DIRECTION / POINT4 / INVALIDATION / TARGET (DIR-FIX) ----
      bool _hasCtx=(m_dir!=0)&&(!IsNa(m_ft));
      bool _flipDn=(m_dir==1)&&_bearCH;
      bool _flipUp=(m_dir==-1)&&_bullCH;
      bool _isRev =(_eLong&&m_dir==-1)||(_eShort&&m_dir==1)||_flipUp||_flipDn;
      bool _spawn =(_eLong||_eShort||_flipUp||_flipDn)&&(!_hasCtx||_isRev);
      if(_spawn)
        {
         int _nd=_eLong?1:_eShort?-1:_flipUp?1:-1;
         //--- order the order-block by ACTUAL price, not pivot recency.
         double _hi=MathMax(m_lastP,m_prevP);
         double _lo=MathMin(m_lastP,m_prevP);
         m_dir=_nd; m_ft=_hi; m_fb=_lo; m_p4h=_hi; m_p4l=_lo; m_cycH=h; m_cycL=l;
         //--- invalidation pinned to the protective extreme.
         m_inv=(_nd==1)?_lo:_hi;
         double _rng=(!IsNa(m_prSH)&&!IsNa(m_prSL))?MathAbs(m_prSH-m_prSL):atrv*5.0;
         m_tgt=(_nd==1)?Nz(m_ft,c)+_rng:Nz(m_fb,c)-_rng;
        }
      if(m_dir==1)  m_cycH=IsNa(m_cycH)?h:MathMax(m_cycH,h);
      if(m_dir==-1) m_cycL=IsNa(m_cycL)?l:MathMin(m_cycL,l);
      int _bosOut=_bullBOS?1:_bearBOS?-1:0;
      int _chOut =_bullCH ?1:_bearCH ?-1:0;

      //---- LIFECYCLE STRUCTURE (BOS1/BOS2/induction) ----
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

      //---- DIRECTION (origin-based) + geometry ----
      int   _wdir   = (!IsNa(m_inv)) ? (c>m_inv?1:(c<m_inv?-1:m_dir)) : m_dir;
      bool  _atFlip = (!IsNa(m_ft)&&!IsNa(m_fb)&&c<=m_ft&&c>=m_fb);
      bool  _expanding = _momExpStrong||_eLong||_eShort||(_wdir==1?_bullImp:_bearImp);
      bool  _atExtreme = _wdir==1 ? (h>=Nz(m_cycH,h)) : _wdir==-1 ? (l<=Nz(m_cycL,l)) : false;
      double _extr   = _wdir==1 ? Nz(m_cycH,c) : Nz(m_cycL,c);
      bool  _extended = (!IsNa(m_inv)) && (MathAbs(_extr-m_inv)>atrv*1.5);
      double _fzMid  = (!IsNa(m_ft)&&!IsNa(m_fb)) ? (m_ft+m_fb)/2.0 : PINE_NA;
      double _retrFrac = (!IsNa(_fzMid)&&MathAbs(_extr-_fzMid)>1e-10) ? MathAbs(_extr-c)/MathAbs(_extr-_fzMid) : 0.0;
      //--- COMPRESSION INDEX (0..100): high when displacement & efficiency are LOW
      double _compIdx = Clamp((1.0-PineMin(_disp/MathMax(dispT,1e-10),1.0))*60.0 + (1.0-PineMin(_eff/MathMax(effT,1e-10),1.0))*40.0, 0.0, 100.0);

      //---- RECURSIVE TRANSITION + DOMINANCE TRANSFER ----
      bool _phase2CH = (m_dir==1 && _bearCH)||(m_dir==-1 && _bullCH);
      if(_reset || (_atExtreme && _extended)){ m_recBrk=0; m_recArm=true; }
      if((m_dir==1 && !IsNa(_pH))||(m_dir==-1 && !IsNa(_pL))) m_recArm=true;
      if((_phase2CH||_oppBOS) && m_recArm && !_atExtreme){ m_recBrk=m_recBrk+1; m_recArm=false; }
      double _recDom = PineMin(MathMax(m_recBrk*(30.0-_compIdx*0.15), _retrFrac*80.0), 100.0);
      bool   _transferDone = _recDom>=50.0;

      //---- SINGLE-LATCH PHASE STATE MACHINE (0 -> 13) ----
      if(_reset) m_pst=0;
      if(m_dir!=0 && !_reset)
        {
         if(m_pst==0 && _expanding) m_pst=1;
         if(m_pst==1 && !_atExtreme && _momDecaying && _physConvexDevel) m_pst=2;
         if(m_pst==2 && !_atExtreme && _momCounter && _physTransfer) m_pst=3;
         if(m_pst==3 && !_atExtreme && (m_bos1||m_bos2||m_indBrk) && _physTransfer) m_pst=4;
         if(m_pst>=1 && m_pst<=7 && _atExtreme && _extended) m_pst=5;
         if(m_pst==5 && !_atExtreme && (m_recBrk>=1 || _momExhaust)) m_pst=7;
         if(m_pst==7 && _transferDone) m_pst=8;
         if(m_pst==8 && _atFlip) m_pst=9;
         if(m_pst==9 && ((m_dir==1 && _bullImp)||(m_dir==-1 && _bearImp))) m_pst=10;
         if(m_pst==10 && (_oppBOS || _physCapacityLow)) m_pst=11;
         if(m_pst==11 && ((m_dir==1 && l<m_fb)||(m_dir==-1 && h>m_ft))) m_pst=12;
         if(m_pst==12 && ((m_dir==1 && _bullCH)||(m_dir==-1 && _bearCH))) m_pst=13;
        }
      int _phase=m_pst;
      if(_phase==5 && m_dir==-1) _phase=6;
      if(_phase==13 && m_dir==-1) _phase=14;

      double _wp = m_pst==0?5.0:m_pst==1?15.0:m_pst==2?25.0:m_pst==3?33.0:m_pst==4?42.0:m_pst==5?55.0:m_pst==7?65.0:m_pst==8?75.0:m_pst==9?85.0:m_pst==10?90.0:m_pst==11?94.0:m_pst==12?97.0:100.0;
      double _cm = PineMin(_convScore,100.0);
      double _mf = PineMin(MathMax(_expScore,MathMax(_absScore,_convScore))*0.70+(m_dir!=0?30.0:0.0),100.0);
      double _frzS=PineMin((_eLong||_eShort?50.0:0.0)+_expScore*0.30+_convScore*0.20,100.0);
      int _dirLabel = _wdir;

      //---- publish outputs ----
      oDir=_dirLabel; oPh=_phase; oSH=m_curSH; oSL=m_curSL; oPSH=m_prSH; oPSL=m_prSL;
      oBos=_bosOut; oCh=_chOut; oP4h=m_p4h; oP4l=m_p4l; oInv=m_inv; oTgt=m_tgt;
      oFt=m_ft; oFb=m_fb; oFs=_frzS; oWp=_wp; oCm=_cm; oMf=_mf;
      oComp=_compIdx; oRec=m_recBrk; oDom=_recDom;

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
   //--- adaptive ladder (Part B): g_ladderTF[] computed in Context
   Struct_FeedEngine(g_se1,  g_ladderTF[0], moment);
   Struct_FeedEngine(g_se3,  g_ladderTF[1], moment);
   Struct_FeedEngine(g_se5,  g_ladderTF[2], moment);
   Struct_FeedEngine(g_se15, g_ladderTF[3], moment);
   Struct_FeedEngine(g_se60, g_ladderTF[4], moment);
   Struct_FeedEngine(g_se240,g_ladderTF[5], moment);
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
//  Live derivation: layer dirs, fractal stack, Engine 1A, exports
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

   //--- V60 extras + per-rung exports
   se5_comp=g_se5.oComp; se5_rec=g_se5.oRec; se5_dom=g_se5.oDom;
   se5_inv=g_se5.oInv; se5_sh=g_se5.oSH; se5_sl=g_se5.oSL; se5_ft=g_se5.oFt; se5_fb=g_se5.oFb;
   se15_tgt=g_se15.oTgt;
   se60_inv=g_se60.oInv; se60_sh=g_se60.oSH; se60_sl=g_se60.oSL; se60_ft=g_se60.oFt; se60_fb=g_se60.oFb;
   se60_tgt=g_se60.oTgt; se60_wp=g_se60.oWp; se60_comp=g_se60.oComp; se60_phCode=g_se60.oPh;
   se240_inv=g_se240.oInv; se240_sh=g_se240.oSH; se240_sl=g_se240.oSL; se240_ft=g_se240.oFt; se240_fb=g_se240.oFb;
   se240_tgt=g_se240.oTgt; se240_wp=g_se240.oWp; se240_comp=g_se240.oComp; se240_phCode=g_se240.oPh;

   //--- full per-rung curve state
   se1_wp=g_se1.oWp;   se1_comp=g_se1.oComp;   se1_rec=g_se1.oRec;   se1_dom=g_se1.oDom;
   se3_wp=g_se3.oWp;   se3_comp=g_se3.oComp;   se3_rec=g_se3.oRec;   se3_dom=g_se3.oDom;
   se15_wp=g_se15.oWp; se15_comp=g_se15.oComp; se15_rec=g_se15.oRec; se15_dom=g_se15.oDom;
   se60_rec=g_se60.oRec; se60_dom=g_se60.oDom;
   se240_rec=g_se240.oRec; se240_dom=g_se240.oDom;

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
