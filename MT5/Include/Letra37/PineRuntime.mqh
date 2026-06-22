//+------------------------------------------------------------------+
//|                                              PineRuntime.mqh      |
//|     Pine Script v6 -> MQL5 runtime compatibility layer           |
//|     Part of the Letra 37 autonomous EA port                      |
//+------------------------------------------------------------------+
//  This module reproduces the primitives that Pine Script provides
//  implicitly so the ported engines can mirror the original logic
//  line-for-line:
//    * na / nz semantics for floating point "missing" values
//    * historical series access  value[n]  via a ring buffer
//    * ta.ema / ta.rma / ta.sma / ta.atr stateful series functions
//    * ta.highest / ta.lowest / math.sum over a window
//    * ta.pivothigh / ta.pivotlow confirmed-pivot detection
//
//  All engines are advanced one CLOSED bar at a time (exactly like
//  Pine evaluates one bar at a time), so every stateful helper here
//  is updated once per bar in the same order as the source script.
//+------------------------------------------------------------------+
#property strict

//--- "na" sentinel.  Pine uses a dedicated NaN; we use a sentinel that
//--- never collides with a real price and provide helpers around it.
#define PINE_NA  (DBL_MAX)

//+------------------------------------------------------------------+
//| na / nz helpers                                                  |
//+------------------------------------------------------------------+
bool IsNa(const double v)            { return(v==PINE_NA || !MathIsValidNumber(v)); }
double Nz(const double v)            { return(IsNa(v) ? 0.0 : v); }
double Nz(const double v,const double rep) { return(IsNa(v) ? rep : v); }
int    NzI(const int v,const int rep)      { return(v==INT_MIN ? rep : v); }

double PineMin(const double a,const double b){ if(IsNa(a)) return b; if(IsNa(b)) return a; return(a<b?a:b); }
double PineMax(const double a,const double b){ if(IsNa(a)) return b; if(IsNa(b)) return a; return(a>b?a:b); }
double Clamp(const double v,const double lo,const double hi){ return(v<lo?lo:(v>hi?hi:v)); }

//+------------------------------------------------------------------+
//| CRing - growable-but-capped historical series (value[n] access)  |
//|   Push() once per bar with the bar's value.                      |
//|   Get(lag): lag 0 = most recently pushed (current bar).          |
//+------------------------------------------------------------------+
class CRing
  {
private:
   double            m_b[];
   int               m_cap;
   long              m_count;   // total values ever pushed
public:
                     CRing(void): m_cap(0), m_count(0) {}
   void              Init(const int cap)
     {
      m_cap = (cap<8 ? 8 : cap);
      ArrayResize(m_b, m_cap);
      ArrayInitialize(m_b, 0.0);
      m_count = 0;
     }
   void              Push(const double v)
     {
      if(m_cap<=0) Init(1024);
      m_b[(int)(m_count % m_cap)] = v;
      m_count++;
     }
   long              Count(void) const { return m_count; }
   bool              Has(const int lag) const { return(lag>=0 && lag<m_cap && (long)lag<m_count); }
   //--- lag 0 = current (last pushed); returns PINE_NA if unavailable
   double            Get(const int lag) const
     {
      if(m_count==0) return PINE_NA;
      if(lag<0 || lag>=m_cap || (long)lag>=m_count) return PINE_NA;
      long idx = m_count-1-lag;
      return m_b[(int)(idx % m_cap)];
     }
   //--- highest / lowest of the most recent `len` values (incl. current)
   double            Highest(const int len) const
     {
      int n=(int)MathMin((long)len,m_count);
      if(n<=0) return PINE_NA;
      double mx=-DBL_MAX;
      for(int i=0;i<n;i++){ double v=Get(i); if(!IsNa(v) && v>mx) mx=v; }
      return(mx==-DBL_MAX?PINE_NA:mx);
     }
   double            Lowest(const int len) const
     {
      int n=(int)MathMin((long)len,m_count);
      if(n<=0) return PINE_NA;
      double mn=DBL_MAX;
      for(int i=0;i<n;i++){ double v=Get(i); if(!IsNa(v) && v<mn) mn=v; }
      return(mn==DBL_MAX?PINE_NA:mn);
     }
   //--- math.sum over most recent `len` values
   double            Sum(const int len) const
     {
      int n=(int)MathMin((long)len,m_count);
      double s=0.0;
      for(int i=0;i<n;i++){ double v=Get(i); if(!IsNa(v)) s+=v; }
      return s;
     }
  };

//+------------------------------------------------------------------+
//| CEma - stateful exponential moving average  (ta.ema)             |
//|   alpha = 2 / (len + 1)                                          |
//+------------------------------------------------------------------+
class CEma
  {
private:
   double            m_val;
   double            m_alpha;
   bool              m_init;
public:
                     CEma(void): m_val(0), m_alpha(0), m_init(false) {}
   void              Init(const int len){ m_alpha=2.0/(len+1.0); m_init=false; m_val=0.0; }
   void              SetAlpha(const double a){ m_alpha=a; }
   double            Update(const double src)
     {
      if(IsNa(src)) return m_val;
      if(!m_init){ m_val=src; m_init=true; }
      else        m_val = m_alpha*src + (1.0-m_alpha)*m_val;
      return m_val;
     }
   double            Value(void) const { return(m_init?m_val:PINE_NA); }
   bool              Ready(void) const { return m_init; }
  };

//+------------------------------------------------------------------+
//| CRma - Wilder running moving average (ta.rma, used by ta.atr)    |
//|   alpha = 1 / len ; seeded with SMA of first `len` samples       |
//+------------------------------------------------------------------+
class CRma
  {
private:
   double            m_val;
   double            m_alpha;
   int               m_len;
   int               m_seen;
   double            m_seedSum;
   bool              m_init;
public:
                     CRma(void): m_val(0), m_alpha(0), m_len(1), m_seen(0), m_seedSum(0), m_init(false) {}
   void              Init(const int len){ m_len=(len<1?1:len); m_alpha=1.0/m_len; m_seen=0; m_seedSum=0.0; m_init=false; m_val=0.0; }
   double            Update(const double src)
     {
      if(IsNa(src)) return (m_init?m_val:PINE_NA);
      if(!m_init)
        {
         m_seen++;
         m_seedSum += src;
         if(m_seen>=m_len){ m_val=m_seedSum/m_len; m_init=true; }
         return (m_init?m_val:PINE_NA);
        }
      m_val = m_alpha*src + (1.0-m_alpha)*m_val;
      return m_val;
     }
   double            Value(void) const { return(m_init?m_val:PINE_NA); }
   bool              Ready(void) const { return m_init; }
  };

//+------------------------------------------------------------------+
//| CSma - simple moving average over a window (ta.sma)              |
//+------------------------------------------------------------------+
class CSma
  {
private:
   CRing             m_r;
   int               m_len;
public:
                     CSma(void): m_len(1) {}
   void              Init(const int len){ m_len=(len<1?1:len); m_r.Init(len+2); }
   double            Update(const double src)
     {
      m_r.Push(IsNa(src)?0.0:src);
      int n=(int)MathMin((long)m_len, m_r.Count());
      if(n<=0) return PINE_NA;
      return m_r.Sum(m_len)/n;
     }
  };

//+------------------------------------------------------------------+
//| Pivot detection helpers.                                         |
//|   Pine ta.pivothigh(src, L, L): confirmed at the current bar; the|
//|   pivot itself sits L bars back. Returns the pivot price or NA.  |
//|   We evaluate using a ring that holds at least 2*L+1 samples.    |
//+------------------------------------------------------------------+
//  ring: series of the source (high for pivothigh, low for pivotlow)
//  leftright: the L parameter (same on both sides)
//  Returns pivot value if bar at lag `leftright` is a strict pivot.
double PivotHigh(const CRing &ring,const int leftright)
  {
   int need = 2*leftright+1;
   if(ring.Count() < need) return PINE_NA;
   double pivot = ring.Get(leftright);
   if(IsNa(pivot)) return PINE_NA;
   for(int i=1;i<=leftright;i++)
     {
      double l = ring.Get(leftright+i); // older (left)
      double r = ring.Get(leftright-i); // newer (right)
      if(IsNa(l) || IsNa(r)) return PINE_NA;
      if(!(pivot> l)) return PINE_NA;
      if(!(pivot> r)) return PINE_NA;
     }
   return pivot;
  }

double PivotLow(const CRing &ring,const int leftright)
  {
   int need = 2*leftright+1;
   if(ring.Count() < need) return PINE_NA;
   double pivot = ring.Get(leftright);
   if(IsNa(pivot)) return PINE_NA;
   for(int i=1;i<=leftright;i++)
     {
      double l = ring.Get(leftright+i);
      double r = ring.Get(leftright-i);
      if(IsNa(l) || IsNa(r)) return PINE_NA;
      if(!(pivot< l)) return PINE_NA;
      if(!(pivot< r)) return PINE_NA;
     }
   return pivot;
  }

//+------------------------------------------------------------------+
//| Rounding helper mirroring Pine math.round                        |
//+------------------------------------------------------------------+
int PineRound(const double v){ return (int)MathRound(v); }
//+------------------------------------------------------------------+
