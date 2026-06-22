//+------------------------------------------------------------------+
//|  SharedState.mqh - cross-module wave-context + forward vars      |
//|                                                                  |
//|  The source declares these in SECTION 8 (and the "FORWARD        |
//|  DECLARATIONS" block) BEFORE the engines that read them, so      |
//|  earlier engines see the PREVIOUS bar's value and SECTION 13     |
//|  (wave spawn) writes the new value. Declaring them here -        |
//|  included right after Context and before every engine module -   |
//|  preserves that exact read-before-write (1-bar lag) behaviour.   |
//+------------------------------------------------------------------+
#property strict

//==================== SECTION 8 - WAVE CONTEXT ====================
int    direction          = 0;
double flipTop            = PINE_NA;
double flipBot            = PINE_NA;
long   obBirthBar         = -1;
int    barsInZone         = 0;
long   contBar            = -1;

double point4OriginHigh   = PINE_NA;
double point4OriginLow    = PINE_NA;
long   point4OriginBar    = -1;

double flipzoneInducPrice = PINE_NA;
double flipzoneInducLow   = PINE_NA;
double flipzoneInducHigh  = PINE_NA;

double inducExpOriginHigh  = PINE_NA;
double inducExpExtremeLow  = PINE_NA;
double inducExpOriginLow   = PINE_NA;
double inducExpExtremeHigh = PINE_NA;

double inducRetrOriginHigh  = PINE_NA;
double inducRetrExtremeLow  = PINE_NA;
double inducRetrOriginLow    = PINE_NA;
double inducRetrExtremeHigh = PINE_NA;

double inducZoneLow  = PINE_NA;
double inducZoneHigh = PINE_NA;

double cycleHigh = PINE_NA;
double cycleLow  = PINE_NA;

int    waveGeneration  = 0;
int    entryCycle      = 0;
bool   isRecursiveWave = false;
int    waveDepth       = 0;
int    lastSpawnDir    = 0;
bool   recursiveComplete = false;

bool   recursiveJustFired = false;
long   recursiveFiredBar  = -1;

double retestHigh = PINE_NA;
double retestLow  = PINE_NA;

//==================== FORWARD-DECLARED VARS =======================
double liqHeat            = 0.0;
bool   nearFlipzone       = false;
double convexityMaturity  = 0.0;
bool   closeInside        = false;
bool   preConvEvidence    = false;
bool   inductionEvidence  = false;

//--- ERF gate flags (read by WaveSpawn before Erf module is included)
bool   erf_entryGate      = true;
bool   erf_suppressRotation = false;

//==================================================================
void SharedState_Init()
  {
   direction=0; flipTop=PINE_NA; flipBot=PINE_NA; obBirthBar=-1; barsInZone=0; contBar=-1;
   point4OriginHigh=PINE_NA; point4OriginLow=PINE_NA; point4OriginBar=-1;
   flipzoneInducPrice=PINE_NA; flipzoneInducLow=PINE_NA; flipzoneInducHigh=PINE_NA;
   inducExpOriginHigh=PINE_NA; inducExpExtremeLow=PINE_NA; inducExpOriginLow=PINE_NA; inducExpExtremeHigh=PINE_NA;
   inducRetrOriginHigh=PINE_NA; inducRetrExtremeLow=PINE_NA; inducRetrOriginLow=PINE_NA; inducRetrExtremeHigh=PINE_NA;
   inducZoneLow=PINE_NA; inducZoneHigh=PINE_NA;
   cycleHigh=PINE_NA; cycleLow=PINE_NA;
   waveGeneration=0; entryCycle=0; isRecursiveWave=false; waveDepth=0; lastSpawnDir=0; recursiveComplete=false;
   recursiveJustFired=false; recursiveFiredBar=-1;
   retestHigh=PINE_NA; retestLow=PINE_NA;
   liqHeat=0.0; nearFlipzone=false; convexityMaturity=0.0;
   closeInside=false; preConvEvidence=false; inductionEvidence=false;
  }
//+------------------------------------------------------------------+
