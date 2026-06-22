//+------------------------------------------------------------------+
//|                                                   Letra37EA.mq5  |
//|     Autonomous Expert Advisor - faithful MQL5 port of the        |
//|     "Letra 37" Pine Script v6 market-physics / SMC engine.       |
//|                                                                  |
//|     The original is a multi-engine wave-lifecycle model:         |
//|       physics -> fixed-TF structure -> Engine 1A phase ->        |
//|       beliefs -> wave spawn -> scoring -> Bayesian ->            |
//|       opportunity/net-edge -> entry/exit/trade-state.            |
//|                                                                  |
//|     This EA reproduces that decision pipeline bar-by-bar and     |
//|     adds hedge-fund-grade execution & risk management.           |
//|                                                                  |
//|     Build order (mirrors the Pine global script):                |
//|       PineRuntime -> Inputs -> Context -> PhysicsEngine ->       |
//|       StructureEngine -> BeliefEngine -> MarketStructure ->      |
//|       Liquidity/Observation -> Geometry/WaveIntel -> WaveSpawn ->|
//|       ERF -> ScoringSignals -> TradeManager -> Dashboard.        |
//+------------------------------------------------------------------+
#property copyright "Letra 37 Port"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Foundation
#include "Include/Letra37/PineRuntime.mqh"
#include "Include/Letra37/Inputs.mqh"
#include "Include/Letra37/Context.mqh"
#include "Include/Letra37/SharedState.mqh"

//--- Engine modules (added part by part)
#include "Include/Letra37/PhysicsEngine.mqh"
#include "Include/Letra37/StructureEngine.mqh"
#include "Include/Letra37/BeliefEngine.mqh"
#include "Include/Letra37/MarketStructure.mqh"
#include "Include/Letra37/ObservationLiquidity.mqh"
#include "Include/Letra37/GeometryWave.mqh"
#include "Include/Letra37/WaveSpawn.mqh"
#include "Include/Letra37/Erf.mqh"
#include "Include/Letra37/TimeIntel.mqh"
#include "Include/Letra37/ScoringSignals.mqh"
#include "Include/Letra37/CurveLife.mqh"
#include "Include/Letra37/TradeManager.mqh"
#include "Include/Letra37/Dashboard.mqh"
#include "Include/Letra37/Pipeline.mqh"   // orchestration (must be last)

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- bind config from inputs into the shared context
   Ctx_LoadInputs();
   SharedState_Init();

   //--- configure trade object
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   //--- initialise engine state
   Phys_Init();
   Struct_InitAll();
   Belief_Init();
   MS_Init();
   ObsLiq_Init();
   GeoWave_Init();
   WaveSpawn_Init();
   Erf_Init();
   Signals_Init();
   TimeIntel_Init();
   CurveLife_Init();
   Trade_Init();

   //--- warm up the engines on history so live decisions are valid
   Ctx_WarmUp();

   Print("Letra37 EA initialised. WorkTF=",EnumToString(InpWorkTF),
         "  tf1=",EnumToString(InpTf1),"  tf2=",EnumToString(InpTf2));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Dash_Destroy();
   Comment("");
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- intrabar management (trailing / breakeven / safety) runs every tick
   Trade_ManageOpen();

   //--- the engine evaluates only on a CLOSED work-TF bar (like Pine bar close)
   datetime t = iTime(_Symbol, InpWorkTF, 0);
   if(t==0) return;
   if(t==g_lastWorkBarTime) return;     // no new work-TF bar yet
   g_lastWorkBarTime = t;

   //--- a new work-TF bar just closed -> advance the full pipeline one step
   Ctx_OnNewWorkBar();

   //--- act on the freshly computed signals
   Trade_OnSignals();

   //--- refresh dashboard
   if(InpShowDashboard) Dash_Update();
  }
//+------------------------------------------------------------------+
