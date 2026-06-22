//+------------------------------------------------------------------+
//|                                                   Inputs.mqh     |
//|     All tunable parameters for the Letra 37 EA.                  |
//|     Names/defaults mirror the original Pine "Letra 37" inputs,   |
//|     plus an Execution/Risk group for autonomous trading.         |
//+------------------------------------------------------------------+
#property strict

//==================== CORE SETTINGS ===============================
input group "Core Settings"
input int    InpPivotLen        = 5;     // Pivot Length
input int    InpAtrLen          = 14;    // ATR Length
input int    InpEffLen          = 10;    // Efficiency Lookback
input int    InpResetBars       = 20;    // Min Bars Before Reset

//==================== DISPLACEMENT & FILTERS ======================
input group "Displacement & Filters"
input double InpImpulseAtrMult  = 1.5;   // Impulse ATR Multiple
input double InpRetrMin         = 0.3;   // Min Retracement
input double InpRetrMax         = 0.8;   // Max Retracement
input double InpEffThresh       = 0.65;  // Efficiency Threshold
input double InpDispThresh      = 1.5;   // Displacement ATR Threshold
input double InpConvMult        = 0.01;  // Convexity ATR Multiplier
input int    InpAcceptBars      = 2;     // Flipzone Acceptance Bars
input int    InpObLookback      = 8;     // Order Block Lookback Bars
input int    InpObMaxBars       = 50;    // OB Max Valid Bars

//==================== MARKET STRUCTURE ============================
input group "Market Structure"
input bool   InpUseStrictStruct = true;  // Use Strict Structure
input int    InpStructLen       = 10;    // Structure Pivot Length
input bool   InpRequireStruct   = true;  // Require Structure Confirm
input double InpChochBufferATR  = 0.75;  // Direction CHoCH Buffer (ATR)

//==================== INDUCEMENT ENGINE ===========================
input group "Inducement Engine"
input int    InpInducLookback   = 80;    // Inducement Lookback Bars
input double InpInducZoneWidth  = 0.25;  // Inducement Zone Half-Width (ATR)
input bool   InpRequirePreConv  = true;  // Require Pre-Convexity Evidence
input bool   InpRequireInduction= true;  // Require Induction Evidence

//==================== LIQUIDITY ENGINE ============================
input group "Liquidity Engine"
input double InpLiqRadius       = 0.25;  // Liquidity Radius (x ATR)
input double InpLiqAgDecay      = 0.95;  // Age Decay Factor
input bool   InpRequireLiqSweep = true;  // Require Liquidity Sweep for Entry
input int    InpLiqSweepLookback= 10;    // Sweep Lookback Bars

//==================== MULTI-TIMEFRAME =============================
input group "Multi-Timeframe"
input ENUM_TIMEFRAMES InpTf1    = PERIOD_M15; // Timeframe 1 (HTF Bias)
input ENUM_TIMEFRAMES InpTf2    = PERIOD_H1;  // Timeframe 2 (HTF Bias)

//==================== EXECUTION CONTROLS ==========================
input group "Execution Controls"
input int    InpBaseLockBars    = 10;    // Base Lock Bars After Entry Fire
input bool   InpRequireHTFAlign = false; // Require HTF Bias Alignment
input double InpExecThreshold   = 5.0;   // Net Edge Execution Threshold

//==================== INTELLIGENCE ENGINE =========================
input group "Intelligence Engine"
input int    InpBeliefSmooth    = 3;     // Belief EMA Smoothing
input double InpConfDecayRate   = 0.02;  // Confidence Decay Rate
input double InpDevReinterp      = 30.0; // Deviation Reinterpret Threshold

//==================== ENERGY RESOLUTION FRAMEWORK =================
input group "Energy Resolution Framework (ERF)"
input double InpErfReadyResW    = 0.25;  // ERF: Recursive Completion Weight
input double InpErfReadyResidW  = 0.20;  // ERF: Delivered Energy Weight
input double InpErfReadyConfW   = 0.15;  // ERF: Confidence Weight
input double InpErfEntryThresh  = 45.0;  // ERF: Entry Gate Threshold
input bool   InpErfGateEnabled  = true;  // ERF: Enable Entry Gate on Signals

//==================== SIGNALS =====================================
input group "Signal Gating"
input bool   InpShowSignals     = true;  // Enable Entry Signal Generation
input bool   InpUseGradeFilter  = true;  // Apply Setup Grade Filter

//==================== TRADE EXECUTION / RISK ======================
input group "Trade Execution & Risk"
input bool   InpEnableTrading   = true;        // Enable Live Order Execution
input ENUM_TIMEFRAMES InpWorkTF = PERIOD_M5;   // Working / Chart-Context Timeframe
input double InpRiskPercent     = 0.5;         // Risk % of equity per trade
input double InpFixedLots       = 0.0;         // Fixed lots (0 = use Risk %)
input double InpSL_ATR          = 1.5;         // Stop Loss (x ATR)
input double InpTP_ATR          = 3.0;         // Take Profit (x ATR, 0 = none)
input bool   InpUseStructSL     = true;        // Use flip-zone / invalidation for SL
input bool   InpUseTrailing     = true;        // Enable ATR trailing stop
input double InpTrailATR        = 2.0;         // Trailing distance (x ATR)
input double InpTrailStartATR   = 1.0;         // Start trailing after (x ATR) profit
input bool   InpUseBreakeven    = true;        // Move SL to breakeven
input double InpBE_ATR          = 1.0;         // Breakeven trigger (x ATR profit)
input bool   InpCloseOnExit     = true;        // Close positions on engine EXIT signal
input int    InpMaxPositions    = 1;           // Max simultaneous positions (this EA)
input int    InpMaxSpreadPoints = 40;          // Max spread (points) to allow entry
input double InpMaxDailyLossPct = 5.0;         // Daily loss limit (% equity, 0=off)
input double InpMaxTotalDDPct   = 20.0;        // Total drawdown halt (% peak equity, 0=off)
input long   InpMagic           = 370037;      // Magic number
input int    InpSlippagePoints  = 20;          // Max deviation (points)
input string InpTradeComment    = "Letra37";   // Order comment

//==================== SESSION FILTER ==============================
input group "Session Filter"
input bool   InpUseSession      = false;       // Restrict trading to a session
input int    InpSessionStartHr  = 7;           // Session start hour (server time)
input int    InpSessionEndHr    = 20;          // Session end hour (server time)
input bool   InpTradeMonday     = true;
input bool   InpTradeFriday     = true;

//==================== DISPLAY =====================================
input group "Display"
input bool   InpShowDashboard   = true;        // Show on-chart dashboard panel
input int    InpDashCorner      = 0;           // Corner (0=TL,1=TR,2=BL,3=BR)
//+------------------------------------------------------------------+
