//+------------------------------------------------------------------+
//|  PhysicsEngine.mqh - SECTION 2: Core Physics Engine              |
//|                                                                  |
//|  Faithful port of f_phys(), which the source computes on the     |
//|  FIXED M5 timeframe so all downstream physics-derived scores are |
//|  timeframe independent. Advanced one CLOSED M5 bar at a time.    |
//|                                                                  |
//|    vel = ema(close-close[1], 3)                                  |
//|    acc = vel - vel[1]                                            |
//|    cvx = acc - acc[1]                                            |
//|    csm = ema(cvx, 3)                                             |
//|    eff = |close-close[effL]| / sum(|close-close[1]|, effL)       |
//|    dsp = (high-low) / atr                                        |
//|                                                                  |
//|  Plus the chart volatility regime derived from atr:              |
//|    volRatio = atr / sma(atr,20) ; volMult = clamp(volRatio,.5,2.5)|
//+------------------------------------------------------------------+
#property strict

//================= GLOBAL PHYSICS OUTPUTS (Pine names) =============
double atr              = PINE_NA;
double velocity         = 0.0;
double acceleration     = 0.0;
double convexity        = 0.0;
double convSmooth       = 0.0;
double efficiency       = 0.0;
double displacement     = 0.0;
double convThreshold    = 0.0;

bool   bullConvShift    = false;
bool   bearConvShift    = false;
bool   bullImpulse      = false;
bool   bearImpulse      = false;
bool   bullMomDecay     = false;
bool   bearMomDecay     = false;
bool   bullMicroImpulse = false;
bool   bearMicroImpulse = false;
bool   phys_vd70        = false;
bool   phys_vd50        = false;
bool   phys_vd85        = false;
bool   phys_vd55x3      = false;
double phys_mom         = 0.0;
bool   phys_accDec      = false;

//--- chart volatility regime (Section 2 tail)
double phys_volRatio    = 1.0;
double phys_volMult     = 1.0;
string phys_volRegime   = "NORMAL";
bool   phys_ready       = false;

//==================================================================
//| CPhysM5 - stateful M5 physics state machine                     |
//==================================================================
class CPhysM5
  {
private:
   CRma              m_atr;        // ta.atr
   CEma              m_velEma;     // ema(close-close[1],3)
   CEma              m_csmEma;     // ema(cvx,3)
   CSma              m_atrSma;     // sma(atr,20)
   CRing             m_close;      // close history (for close[effL])
   CRing             m_absdiff;    // |close-close[1]| history
   CRing             m_vel;        // velocity history (vel[1], vel[3])
   CRing             m_acc;        // acceleration history (acc[1])
   CRing             m_csm;        // convSmooth history (csm[1])
   double            m_prevClose;
   bool              m_havePrev;
public:
   void              Init()
     {
      m_atr.Init(cfg_atrLen);
      m_velEma.Init(3);
      m_csmEma.Init(3);
      m_atrSma.Init(20);
      m_close.Init(cfg_effLen+4);
      m_absdiff.Init(cfg_effLen+4);
      m_vel.Init(8);
      m_acc.Init(8);
      m_csm.Init(8);
      m_prevClose = PINE_NA;
      m_havePrev  = false;
     }

   //--- feed one closed M5 bar
   void              Update(const double o,const double h,const double l,const double c)
     {
      //--- true range / atr
      double tr;
      if(!m_havePrev) tr = h-l;
      else            tr = MathMax(h-l, MathMax(MathAbs(h-m_prevClose), MathAbs(l-m_prevClose)));
      double _atr = m_atr.Update(tr);

      //--- velocity = ema(close - close[1], 3)
      double dc = m_havePrev ? (c - m_prevClose) : 0.0;
      double _vel = m_velEma.Update(dc);

      double velPrev  = m_vel.Has(0) ? m_vel.Get(0) : _vel;   // becomes vel[1] after push
      double _acc = _vel - velPrev;
      double accPrev  = m_acc.Has(0) ? m_acc.Get(0) : _acc;   // becomes acc[1] after push
      double _cvx = _acc - accPrev;
      double _csm = m_csmEma.Update(_cvx);
      double csmPrev  = m_csm.Has(0) ? m_csm.Get(0) : _csm;   // becomes csm[1] after push

      //--- efficiency
      double _eff = 0.0;
      //--- push close first so history aligns, then read close[effL]
      m_close.Push(c);
      m_absdiff.Push(MathAbs(dc));
      if(m_close.Has(cfg_effLen))
        {
         double cEffL = m_close.Get(cfg_effLen);
         double mv = MathAbs(c - cEffL);
         double ps = m_absdiff.Sum(cfg_effLen);
         _eff = (ps>0.0) ? mv/ps : 0.0;
        }

      double atrSafe = MathMax(IsNa(_atr)?0.0:_atr, 1e-10);
      double _dsp = (h-l)/atrSafe;
      double _cth = (IsNa(_atr)?0.0:_atr) * cfg_convMult;

      double effT  = cfg_effThresh;
      double dispT = cfg_dispThresh;

      //--- convexity shift (csm crossing +/- threshold)
      bool _bCS = (_csm >  _cth) && (csmPrev <=  _cth);
      bool _rCS = (_csm < -_cth) && (csmPrev >= -_cth);

      bool _bImp = (_eff>effT) && (_vel>velPrev) && (_acc>0) && (c>o) && (_dsp>dispT);
      bool _rImp = (_eff>effT) && (_vel<velPrev) && (_acc<0) && (c<o) && (_dsp>dispT);
      bool _bDec = (MathAbs(_acc) < MathAbs(accPrev)*0.8) && (_vel>0);
      bool _rDec = (MathAbs(_acc) < MathAbs(accPrev)*0.8) && (_vel<0);
      bool _bMic = (_eff>effT*0.80) && (_vel>velPrev) && (_acc>0) && (c>o) && (_dsp>dispT*0.50);
      bool _rMic = (_eff>effT*0.80) && (_vel<velPrev) && (_acc<0) && (c<o) && (_dsp>dispT*0.50);

      double velAbsPrev = MathAbs(velPrev);
      bool _vd70 = MathAbs(_vel) < velAbsPrev*0.70;
      bool _vd50 = MathAbs(_vel) < velAbsPrev*0.50;
      bool _vd85 = MathAbs(_vel) < velAbsPrev*0.85;
      double vel3 = m_vel.Has(2) ? m_vel.Get(2) : velPrev;   // vel[3] (after push, current is [0])
      bool _vd55x3 = MathAbs(_vel) < MathAbs(vel3)*0.55;
      double _mom = _vel - velPrev;
      bool _accDec = MathAbs(_acc) < MathAbs(accPrev);

      //--- commit history
      m_vel.Push(_vel);
      m_acc.Push(_acc);
      m_csm.Push(_csm);
      m_prevClose = c;
      m_havePrev  = true;

      //--- atr sma + vol regime (Section 2 tail; updated per M5 bar)
      double _atrSma = m_atrSma.Update(IsNa(_atr)?0.0:_atr);
      double vr = (IsNa(_atrSma)||_atrSma<=0.0) ? 1.0 : (IsNa(_atr)?0.0:_atr)/MathMax(_atrSma,1e-10);

      //--- publish globals
      atr           = _atr;
      velocity      = _vel;
      acceleration  = _acc;
      convexity     = _cvx;
      convSmooth    = _csm;
      efficiency    = _eff;
      displacement  = _dsp;
      convThreshold = _cth;
      bullConvShift = _bCS; bearConvShift = _rCS;
      bullImpulse   = _bImp; bearImpulse   = _rImp;
      bullMomDecay  = _bDec; bearMomDecay  = _rDec;
      bullMicroImpulse = _bMic; bearMicroImpulse = _rMic;
      phys_vd70 = _vd70; phys_vd50 = _vd50; phys_vd85 = _vd85; phys_vd55x3 = _vd55x3;
      phys_mom  = _mom;  phys_accDec = _accDec;

      phys_volRatio  = vr;
      phys_volMult   = Clamp(vr, 0.5, 2.5);
      phys_volRegime = (vr>1.5) ? "HIGH" : (vr<0.7 ? "LOW" : "NORMAL");
      phys_ready     = m_atr.Ready() && m_close.Has(cfg_effLen);
     }

   datetime          lastOpen;
  };

CPhysM5 g_phys;

//==================================================================
void Phys_Init()
  {
   g_phys.Init();
   g_phys.lastOpen = 0;
   phys_ready = false;
  }

//==================================================================
//  Feed all closed M5 bars up to `moment`
//==================================================================
void Phys_Feed(const datetime moment)
  {
   int shifts[];
   int n = Ctx_PendingBars(PERIOD_M5, g_phys.lastOpen, moment, shifts);
   for(int i=0;i<n;i++)
     {
      int s = shifts[i];
      double o=iOpen(_Symbol,PERIOD_M5,s);
      double h=iHigh(_Symbol,PERIOD_M5,s);
      double l=iLow (_Symbol,PERIOD_M5,s);
      double c=iClose(_Symbol,PERIOD_M5,s);
      if(o==0&&h==0&&l==0&&c==0) continue;
      g_phys.Update(o,h,l,c);
      g_phys.lastOpen = iTime(_Symbol,PERIOD_M5,s);
     }
  }
//+------------------------------------------------------------------+
