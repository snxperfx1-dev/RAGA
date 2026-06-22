//+------------------------------------------------------------------+
//|  CurveTree.mqh - F72 literal recursive curve tree                |
//|                                                                  |
//|  Recursion is EVENT-generated, not timeframe-generated: a        |
//|  Phase-2 CHoCH against the owning curve spawns a CHILD curve     |
//|  (same lifecycle, opposite orientation). Every node is just      |
//|  another curve (Principle 1/12).                                 |
//|                                                                  |
//|   * Ownership (Principle 8) = the shallowest curve that still    |
//|     holds energy; a child only takes over once the parent        |
//|     dissipates below the energy floor.                           |
//|   * Energy dynamics: a node gains energy while it keeps making   |
//|     progress (continuation) and decays when it stalls; at zero   |
//|     it dies (merges back into the parent).                       |
//|   * Recursion BUDGET (Principle 3/4) from compression: wide      |
//|     curve -> ~1 deep recursion; failure-swing (high compression) |
//|     -> up to 4 tiny ones. A CHoCH only spawns a child while the  |
//|     budget has room.                                             |
//|   * FU-MERGE / ownership transfer (Principle 9): a counter child |
//|     that respects the parent FU flip and reacts (does not break  |
//|     it) MERGES back into the parent (Camp B -> Camp A, parent     |
//|     campaign continues); one that BREAKS the parent flip is a     |
//|     genuine handoff (TRANSFERRED, new campaign).                  |
//|   * Each node emits an EMERGENT phase from its own energy /       |
//|     maturity / depth (curve -> phase, Principle 1).               |
//|                                                                  |
//|  The tree owner is the authoritative "which curve owns price"    |
//|  read consumed by the ownership / curve-life engines.            |
//+------------------------------------------------------------------+
#property strict

//================= NODE TYPE ======================================
struct CurveNode
  {
   int    id;
   int    parent;
   int    dir;
   double origin;
   double extreme;
   double energy;
   bool   alive;
   int    depth;
   string state;
   long   bar;
   double comp;
   double mat;
   int    srcTf;     // 0 = chart/M5
  };

//================= TREE OUTPUTS ===================================
int    ct_treeAlive=0, ct_treeDepth=0, ct_budgetDepth=1;
int    ct_ownDir=0, ct_ownDepth=0;
double ct_ownEnergy=0.0, ct_ownOrig=PINE_NA, ct_ownExt=PINE_NA;
string ct_ownState="-";
bool   ct_merged=false, ct_transferred=false;
string ct_ownStateTx="aligned with parent";
int    ct_childDir=0, ct_parentDir=0;

//--- internal state
CurveNode g_tree[];
int  g_nodeSeq=0;
double g_ct_prevInv=PINE_NA;   // detect M5 wave-origin change
long   g_ct_bar5=0;
double g_ownMinE=12.0;

void CurveTree_Init()
  {
   ArrayResize(g_tree,0);
   g_nodeSeq=0; g_ct_prevInv=PINE_NA; g_ct_bar5=0;
  }

//--- emergent phase from a node's own energy / maturity / depth
string NodeState(const int d,const double e,const int dep,const double cmp,const double mat)
  {
   if(dep>0)
      return e>=70.0 ? "Transition - recursive expansion" :
             e>=40.0 ? "Transition - recursive induction" : "Transition - recursive liquidation";
   if(mat<12.0) return "Point 4 Origin";
   if(e>=78.0 && mat>=70.0) return d==1 ? "New High" : d==-1 ? "New Low" : "Climax";
   if(mat<35.0) return "Expansion";
   if(mat<55.0) return "Expansion Pre-Convexity";
   if(e>=55.0)  return "Expansion Induction";
   if(e>=35.0)  return "Expansion Liquidity";
   if(cmp>=60.0) return "Retracement Pre-Convexity";
   if(e>=18.0)  return "Retracement Induction";
   return "Retracement";
  }

void CurveTree_Compute()
  {
   double cl=C_close(), op=C_open(), hi=C_high(), lo=C_low();

   //--- track the bar the M5 wave origin last changed (so a curve box/age spans its own leg)
   if(IsNa(g_ct_prevInv) || se5_inv!=g_ct_prevInv){ g_ct_bar5=g_barIndex; g_ct_prevInv=se5_inv; }

   int n=ArraySize(g_tree);

   //--- pre-owner (Principle 8): shallowest alive node with energy; fallback highest energy
   int    preOwn=-1; double preE=-1.0; int preDepth=999;
   for(int i=0;i<n;i++)
     {
      if(g_tree[i].alive && g_tree[i].energy>=g_ownMinE &&
         (g_tree[i].depth<preDepth || (g_tree[i].depth==preDepth && g_tree[i].energy>preE)))
        { preDepth=g_tree[i].depth; preE=g_tree[i].energy; preOwn=i; }
     }
   if(preOwn<0)
      for(int i=0;i<n;i++)
         if(g_tree[i].alive && g_tree[i].energy>preE){ preE=g_tree[i].energy; preOwn=i; }

   //--- context anchor = chart (M5) wave
   int    ctxDir = l0_dir;
   double ctxOrig= se5_inv;
   double ctxExt = ctxDir==1 ? MathMax(Nz(cycleHigh,hi),hi) : ctxDir==-1 ? MathMin(Nz(cycleLow,lo),lo) : cl;

   //--- seed / re-seed the root when no living curve owns price
   if(preOwn<0 && ctxDir!=0 && !IsNa(ctxOrig))
     {
      g_nodeSeq++;
      int idx=ArraySize(g_tree); ArrayResize(g_tree, idx+1);
      g_tree[idx].id=g_nodeSeq; g_tree[idx].parent=-1; g_tree[idx].dir=ctxDir;
      g_tree[idx].origin=ctxOrig; g_tree[idx].extreme=ctxExt;
      g_tree[idx].energy=MathMax(40.0, Nz(ede_expansionEnergy,60.0));
      g_tree[idx].alive=true; g_tree[idx].depth=0; g_tree[idx].state="Expansion";
      g_tree[idx].bar=g_barIndex; g_tree[idx].comp=se5_comp; g_tree[idx].mat=se5_wp; g_tree[idx].srcTf=0;
      n=ArraySize(g_tree);
     }

   //--- recursion budget from compression (Principle 3/4)
   double gComp=se5_comp;
   ct_budgetDepth=(int)MathMax(1.0, MathMin(4.0, 1.0+MathRound(gComp/33.0)));

   //--- event-generated CHILD: a chart-TF Phase-2 CHoCH against the owner spawns
   //    an inverse curve while the recursion budget has room.
   if(preOwn>=0)
     {
      int pd=g_tree[preOwn].dir; int pdep=g_tree[preOwn].depth; int pid=g_tree[preOwn].id;
      bool counterCH=(pd==1 && bearCHoCH)||(pd==-1 && bullCHoCH);
      if(counterCH && (pdep+1<=ct_budgetDepth))
        {
         g_nodeSeq++;
         int idx=ArraySize(g_tree); ArrayResize(g_tree, idx+1);
         g_tree[idx].id=g_nodeSeq; g_tree[idx].parent=pid; g_tree[idx].dir=-pd;
         g_tree[idx].origin=cl; g_tree[idx].extreme=cl;
         g_tree[idx].energy=MathMax(25.0, Nz(ede_expansionEnergy,50.0)*0.85);
         g_tree[idx].alive=true; g_tree[idx].depth=pdep+1; g_tree[idx].state="Transition - recursive expansion";
         g_tree[idx].bar=g_barIndex; g_tree[idx].comp=se5_comp; g_tree[idx].mat=se5_wp; g_tree[idx].srcTf=0;
         n=ArraySize(g_tree);
        }
     }

   //--- update living nodes
   for(int i=0;i<n;i++)
     {
      if(!g_tree[i].alive) continue;
      if(g_tree[i].depth==0)
        {
         //--- root mirrors the chart wave (dir / origin / extreme / bar)
         g_tree[i].dir=l0_dir;
         g_tree[i].bar=g_ct_bar5;
         double prevExt=g_tree[i].extreme;
         bool prog = g_tree[i].dir==1 ? (hi>Nz(prevExt,hi)) : (lo<Nz(prevExt,lo));
         g_tree[i].origin=se5_inv;
         g_tree[i].extreme=g_tree[i].dir==1 ? se5_sh : se5_sl;
         g_tree[i].energy=prog ? MathMin(100.0,g_tree[i].energy+7.0) : MathMax(0.0,g_tree[i].energy-2.0);
        }
      else
        {
         double prevExt=g_tree[i].extreme;
         bool prog = g_tree[i].dir==1 ? (hi>Nz(prevExt,hi)) : (lo<Nz(prevExt,lo));
         g_tree[i].extreme=g_tree[i].dir==1 ? MathMax(Nz(prevExt,hi),hi) : MathMin(Nz(prevExt,lo),lo);
         g_tree[i].energy=prog ? MathMin(100.0,g_tree[i].energy+7.0) : MathMax(0.0,g_tree[i].energy-2.0);
        }
      g_tree[i].mat = se5_wp;
      g_tree[i].comp= se5_comp;
      g_tree[i].state=NodeState(g_tree[i].dir, g_tree[i].energy, g_tree[i].depth, g_tree[i].comp, g_tree[i].mat);
      if(g_tree[i].energy<=2.0) g_tree[i].alive=false;
     }

   //--- cap tree size
   while(ArraySize(g_tree)>60) ArrayRemove(g_tree,0,1);
   n=ArraySize(g_tree);

   //--- summary + final owner (Principle 8)
   ct_treeAlive=0; ct_treeDepth=0;
   int ownF=-1; double ownFE=-1.0; int ownDepth=999;
   for(int i=0;i<n;i++)
     {
      if(!g_tree[i].alive) continue;
      ct_treeAlive++;
      if(g_tree[i].depth>ct_treeDepth) ct_treeDepth=g_tree[i].depth;
      if(g_tree[i].energy>=g_ownMinE && (g_tree[i].depth<ownDepth || (g_tree[i].depth==ownDepth && g_tree[i].energy>ownFE)))
        { ownDepth=g_tree[i].depth; ownFE=g_tree[i].energy; ownF=i; }
     }
   if(ownF<0)
      for(int i=0;i<n;i++)
         if(g_tree[i].alive && g_tree[i].energy>ownFE){ ownFE=g_tree[i].energy; ownF=i; }

   if(ownF>=0)
     {
      ct_ownDir=g_tree[ownF].dir; ct_ownDepth=g_tree[ownF].depth; ct_ownEnergy=g_tree[ownF].energy;
      ct_ownState=g_tree[ownF].state; ct_ownOrig=g_tree[ownF].origin; ct_ownExt=g_tree[ownF].extreme;
     }
   else
     { ct_ownDir=0; ct_ownDepth=0; ct_ownEnergy=0.0; ct_ownState="-"; ct_ownOrig=PINE_NA; ct_ownExt=PINE_NA; }

   //--- FU-MERGE / ownership transfer (Principle 9)
   ct_childDir = l0_dir;
   ct_parentDir = (l2_dir+l4_dir)!=0 ? ((l2_dir+l4_dir)>0?1:-1) : l1_dir;
   bool counterChild = (ct_childDir!=0 && ct_parentDir!=0 && ct_childDir!=ct_parentDir);
   double pFlipTop = (!IsNa(se60_ft)&&!IsNa(se60_fb)) ? MathMax(se60_ft,se60_fb) : PINE_NA;
   double pFlipBot = (!IsNa(se60_ft)&&!IsNa(se60_fb)) ? MathMin(se60_ft,se60_fb) : PINE_NA;
   bool atParentFU = (!IsNa(pFlipTop)&&!IsNa(pFlipBot)&&hi>=pFlipBot&&lo<=pFlipTop);
   bool reactPar = ct_parentDir==1 ? (bullImpulse||cl>op) : ct_parentDir==-1 ? (bearImpulse||cl<op) : false;
   bool brokePar = (!IsNa(pFlipBot)&&!IsNa(pFlipTop)) && (ct_parentDir==1 ? cl<pFlipBot : ct_parentDir==-1 ? cl>pFlipTop : false);
   ct_merged     = counterChild && atParentFU && reactPar && !brokePar;
   ct_transferred= counterChild && brokePar;
   ct_ownStateTx = ct_transferred ? "TRANSFERRED - new campaign" :
                   ct_merged ? "MERGED -> parent (B->A)" :
                   counterChild ? "child recursion active" : "aligned with parent";
  }
//+------------------------------------------------------------------+
