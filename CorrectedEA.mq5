#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.02"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/OrderInfo.mqh>

CTrade        trade;
CPositionInfo pos;
COrderInfo    ord;

// ================== Gelişmiş Koruma Ayarları ===================
input bool   UseSpreadFilter         = true;     // Spread kontrolü aktif mi?
input double MaxSpreadPoints         = 35;       // Maksimum izin verilen spread (points)
input bool   AutoAdjustSpread        = true;     // Broker spreadine göre dinamik limit
input double SpreadMultiplier        = 1.8;      // Dinamik spread çarpanı (EMA bazlı)
input int    SpreadEmaPeriod         = 12;       // Spread EMA periyodu
input bool   UseTickVolumeCheck      = true;     // Likidite kontrolü (tick volume)
input int    MinTickVolume           = 100;      // Minimum tick volume
input int    MinPrevTickVolume       = 100;      // Minimum bir önceki bar tick volume
input int    SlippagePoints          = 50;       // Emir gönderim toleransı (slippage)
input bool   TradeOnlyWhenConnected  = true;     // Bağlantı kontrolü
input int    MaxPingMilliseconds     = 150;      // Maksimum ping süresi
input int    BarExecutionDelay       = 250;      // ms cinsinden bekleme (veri oturması için)
input int    MaxOrderRetries         = 3;        // Emir tekrarı
input int    RetryDelayMilliseconds  = 120;      // Emir tekrarları arasındaki bekleme (ms)
input bool   EnableFileLogging       = false;    // Logları dosyaya yaz
input string LogFileName             = "Execution_Log.csv";
// ================================================================

// === Kullanıcı Ayarları ===
input double          RiskPercent = 3;             // Risk as % of Trading Capital
input int             Tppoints = 200;              // Take Profit (10 points = 1 pip)
input int             Slpoints = 200;              // Stoploss Points (10 points = 1pip)
input int             TslTriggerPoints = 15;
input int             TslPoints = 10;
input ENUM_TIMEFRAMES Timeframe = PERIOD_CURRENT;
input int             InpMagic = 298347;
input string          TradeComment = "Scalping Robot";

enum Hour {Inactive=0, _0100=1, _0200=2, _0300=3, _0400=4, _0500=5, _0600=6, _0700=7, _0800=8, _0900=9, _1000=10, _1100=11, _1200=12, _1300=13, _1400=14, _1500=15, _1600=16, _1700=17, _1800=18, _1900=19, _2000=20, _2100=21, _2200=22, _2300=23};
input Hour SHInput=0; // Start Hour
input Hour EHInput=0; // End Hour

int SHChoice;
int EHChoice;

int BarsN =5;
int ExpirationBars =100;
int OrderDistPoints =100;

// ===================== Global Helpers ==========================
double                 g_spreadEma = 0.0;
bool                   g_spreadEmaInitialized = false;
datetime               g_currentBarTime = 0;
bool                   g_barProcessed = true;
ulong                  g_barReadyTimestamp = 0;
int                    g_gmtOffsetSeconds = 0;
int                    g_logHandle = INVALID_HANDLE;
ENUM_ORDER_TYPE_FILLING g_fillingMode = ORDER_FILLING_FOK;
MqlTick                g_lastTick;
bool                   g_fileLoggingEnabled = false;

// ===================== Yardımcı Fonksiyonlar ===================
void   InitializeLogging();
void   CloseLogging();
void   LogMessage(const string message);
void   UpdateGmtOffset(const bool force=false);
bool   EnsureSymbolSynchronization(const bool isInit);
bool   EnsureTradingEnvironment();
void   UpdateSpreadStats(const double spreadPoints);
double GetAllowedSpreadLimit();
bool   ValidateSpread();
bool   ValidateTickVolume();
bool   ShouldProcessCurrentBar();
ENUM_ORDER_TYPE_FILLING DetectFillingMode();
bool   SendPendingOrder(ENUM_ORDER_TYPE orderType,double volume,double price,double sl,double tp,datetime expiration);
bool   NeedRetry(const uint retcode,const int lastError,const int attempt);
void   DelayForRetry();
double NormalizeVolume(const double volume);
bool   ModifyPosition(const ulong ticket,const double sl,const double tp);
bool   UpdateLastTick();
double findHigh();
double findLow();
void   SendBuyOrder(double entry);
void   SendSellOrder(double entry);
double calcLots(double slPoints);
void   CloseAllOrders();
void   TrailStop();

// ===================== INIT ==========================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetAsyncMode(false);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_fillingMode = DetectFillingMode();
   InitializeLogging();
   UpdateGmtOffset(true);

   if(!EnsureSymbolSynchronization(true))
      return(INIT_FAILED);

   g_currentBarTime = iTime(_Symbol, Timeframe, 0);
   g_barProcessed   = true;
   g_barReadyTimestamp = GetTickCount();

   ChartSetInteger(0,CHART_SHOW_GRID,false);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   CloseLogging();
}

// =====================================================

void OnTick()
{
   if(!UpdateLastTick())
      return;

   if(!EnsureTradingEnvironment())
      return;

   UpdateSpreadStats((g_lastTick.ask-g_lastTick.bid)/_Point);

   if(UseSpreadFilter && !ValidateSpread())
      return;

   if(UseTickVolumeCheck && !ValidateTickVolume())
      return;

   UpdateGmtOffset();

   if(!EnsureSymbolSynchronization(false))
      return;

   if(!ShouldProcessCurrentBar())
      return;

   TrailStop();

   MqlDateTime time;
   TimeToStruct(TimeCurrent(),time);
   int Hournow = time.hour;
   SHChoice = (int)SHInput;
   EHChoice = (int)EHInput;

   if(Hournow<SHChoice){CloseAllOrders(); return;}
   if(Hournow>=EHChoice && EHChoice!=0){CloseAllOrders(); return;}

   int BuyTotal=0;
   int SellTotal=0;

   for (int i=PositionsTotal()-1; i>=0; i--)
   {
       if(pos.SelectByIndex(i))
       {
          if(pos.PositionType()==POSITION_TYPE_BUY && pos.Symbol()==_Symbol && pos.Magic()==InpMagic) BuyTotal++;
          if(pos.PositionType()==POSITION_TYPE_SELL && pos.Symbol()==_Symbol && pos.Magic()==InpMagic) SellTotal++;
       }
   }
   for (int i=OrdersTotal()-1; i>=0; i--)
   {
       if(ord.SelectByIndex(i))
       {
          if(ord.OrderType()==ORDER_TYPE_BUY_STOP && ord.Symbol()==_Symbol && ord.Magic()==InpMagic) BuyTotal++;
          if(ord.OrderType()==ORDER_TYPE_SELL_STOP && ord.Symbol()==_Symbol && ord.Magic()==InpMagic) SellTotal++;
       }
   }

   if(BuyTotal <=0)
   {
       double high = findHigh();
       if(high > 0) SendBuyOrder(high);
   }

   if(SellTotal <=0)
   {
       double low = findLow();
       if(low > 0) SendSellOrder(low);
   }
}

// ===================== FONKSİYONLAR ======================
bool UpdateLastTick()
{
   if(SymbolInfoTick(_Symbol, g_lastTick))
      return(true);

   ZeroMemory(g_lastTick);
   LogMessage("Tick bilgisi alınamadı, işlem durduruldu.");
   return(false);
}

void InitializeLogging()
{
   g_fileLoggingEnabled = EnableFileLogging;
   if(!g_fileLoggingEnabled)
      return;

   g_logHandle = FileOpen(LogFileName, FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(g_logHandle == INVALID_HANDLE)
   {
      PrintFormat("Log dosyası açılamadı: %s", LogFileName);
      g_fileLoggingEnabled = false;
      return;
   }
   FileSeek(g_logHandle, 0, SEEK_END);
   LogMessage("=== EA Başlatıldı ===");
}

void CloseLogging()
{
   if(g_logHandle != INVALID_HANDLE)
   {
      LogMessage("=== EA Durduruldu ===");
      FileClose(g_logHandle);
      g_logHandle = INVALID_HANDLE;
   }
   g_fileLoggingEnabled = false;
}

void LogMessage(const string message)
{
   Print(message);
   if(g_fileLoggingEnabled && g_logHandle != INVALID_HANDLE)
   {
      string line = StringFormat("%s,%s", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), message);
      FileWriteString(g_logHandle, line + "\r\n");
      FileFlush(g_logHandle);
   }
}

void UpdateGmtOffset(const bool force)
{
   static datetime lastCheck = 0;
   datetime now = TimeCurrent();
   if(!force && (now - lastCheck) < 900) // 15 dakika
      return;

   datetime serverTime = TimeTradeServer();
   datetime gmtTime    = TimeGMT();
   if(serverTime == 0 || gmtTime == 0)
      return;

   int offset = (int)(serverTime - gmtTime);
   if(offset != g_gmtOffsetSeconds)
   {
      g_gmtOffsetSeconds = offset;
      LogMessage(StringFormat("Broker GMT offset güncellendi: %d saniye", g_gmtOffsetSeconds));
   }
   lastCheck = now;
}

bool EnsureSymbolSynchronization(const bool isInit)
{
   if(SeriesInfoInteger(_Symbol, Timeframe, SERIES_SYNCHRONIZED))
      return(true);

   ResetLastError();
   MqlRates rates[];
   if(CopyRates(_Symbol, Timeframe, 0, 2, rates) <= 0)
   {
      int err = GetLastError();
      if(isInit)
         LogMessage(StringFormat("Seri senkronizasyonu başarısız (%d)", err));
      return(false);
   }
   return(SeriesInfoInteger(_Symbol, Timeframe, SERIES_SYNCHRONIZED) != 0);
}

bool EnsureTradingEnvironment()
{
   if(TradeOnlyWhenConnected && !TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      LogMessage("⚠️ Bağlantı yok, işlem yapılmadı.");
      return(false);
   }

   if(TradeOnlyWhenConnected)
   {
      long ping = TerminalInfoInteger(TERMINAL_PING_LAST);
      if(ping > 0 && ping > MaxPingMilliseconds)
      {
         LogMessage(StringFormat("Ping yüksek (%ld ms) => işlem iptal", ping));
         return(false);
      }
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      LogMessage("Terminal ticarete izin vermiyor.");
      return(false);
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      LogMessage("Hesap ticarete izinli değil.");
      return(false);
   }

   long tradeMode = 0;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE, tradeMode))
      return(false);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      LogMessage(StringFormat("Sembol ticarete kapalı (mode=%ld).", tradeMode));
      return(false);
   }

   return(true);
}

void UpdateSpreadStats(const double spreadPoints)
{
   if(spreadPoints <= 0)
      return;

   if(!g_spreadEmaInitialized)
   {
      g_spreadEma = spreadPoints;
      g_spreadEmaInitialized = true;
      return;
   }

   double period = MathMax(1.0, (double)SpreadEmaPeriod);
   double alpha = 2.0 / (period + 1.0);
   g_spreadEma = alpha * spreadPoints + (1.0 - alpha) * g_spreadEma;
}

double GetAllowedSpreadLimit()
{
   double allowed = MaxSpreadPoints;
   if(AutoAdjustSpread && g_spreadEmaInitialized)
   {
      double dynamicLimit = g_spreadEma * SpreadMultiplier;
      if(allowed <= 0)
         allowed = dynamicLimit;
      else
         allowed = MathMin(allowed, dynamicLimit);
   }
   return(allowed);
}

bool ValidateSpread()
{
   double spread = (g_lastTick.ask - g_lastTick.bid) / _Point;
   double allowed = GetAllowedSpreadLimit();
   if(allowed > 0 && spread > allowed)
   {
      LogMessage(StringFormat("Spread çok geniş (%.1f) > izin (%.1f) => işlem iptal", spread, allowed));
      return(false);
   }
   return(true);
}

bool ValidateTickVolume()
{
   long currentVolume = (long)iVolume(_Symbol, Timeframe, 0);
   long previousVolume = (long)iVolume(_Symbol, Timeframe, 1);
   long validated = (currentVolume > previousVolume ? currentVolume : previousVolume);

   if(validated < MinTickVolume)
   {
      LogMessage(StringFormat("Likidite yetersiz (şimdiki=%ld, önceki=%ld) => işlem iptal", currentVolume, previousVolume));
      return(false);
   }

   int barsAvailable = Bars(_Symbol, Timeframe);
   if(barsAvailable > 1 && previousVolume < MinPrevTickVolume)
   {
      LogMessage(StringFormat("Önceki bar hacmi düşük (%ld < %d)", previousVolume, MinPrevTickVolume));
      return(false);
   }

   return(true);
}

bool ShouldProcessCurrentBar()
{
   datetime barTime = iTime(_Symbol, Timeframe, 0);

   if(barTime != g_currentBarTime)
   {
      g_currentBarTime = barTime;
      g_barProcessed = false;
      g_barReadyTimestamp = GetTickCount() + (BarExecutionDelay > 0 ? (ulong)BarExecutionDelay : 0);
      return(false);
   }

   if(g_barProcessed)
      return(false);

   if(BarExecutionDelay > 0 && GetTickCount() < g_barReadyTimestamp)
      return(false);

   g_barProcessed = true;
   return(true);
}

ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   long fillingMode = SYMBOL_FILLING_FOK;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE, fillingMode))
      return(ORDER_FILLING_FOK);

   if(fillingMode == SYMBOL_FILLING_IOC)
      return(ORDER_FILLING_IOC);

   return(ORDER_FILLING_FOK);
}

bool SendPendingOrder(ENUM_ORDER_TYPE orderType,double volume,double price,double sl,double tp,datetime expiration)
{
   if(volume <= 0)
   {
      LogMessage("Hesaplanan lot geçersiz, emir gönderilmedi.");
      return(false);
   }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   long priceDigits = _Digits;
   SymbolInfoInteger(_Symbol, SYMBOL_DIGITS, priceDigits);
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   request.action      = TRADE_ACTION_PENDING;
   request.symbol      = _Symbol;
   request.magic       = InpMagic;
   request.comment     = TradeComment;
   request.volume      = NormalizeVolume(MathMax(volume, minVolume));
   request.price       = NormalizeDouble(price,  (int)priceDigits);
   request.sl          = NormalizeDouble(sl,     (int)priceDigits);
   request.tp          = NormalizeDouble(tp,     (int)priceDigits);
   request.deviation   = (uint)SlippagePoints;
   request.type        = orderType;
   request.type_time   = ORDER_TIME_SPECIFIED;
   request.expiration  = expiration;
   request.type_filling= g_fillingMode;

   for(int attempt = 0; attempt < MathMax(1, MaxOrderRetries); attempt++)
   {
      ResetLastError();
      if(OrderSend(request, result))
      {
         LogMessage(StringFormat("Emir gönderildi (ticket=%llu, type=%d, volume=%.2f)", result.order, (int)orderType, request.volume));
         return(true);
      }

      int lastErr = GetLastError();
      LogMessage(StringFormat("Emir reddedildi (retcode=%u, err=%d, attempt=%d)", result.retcode, lastErr, attempt+1));

      if(!NeedRetry(result.retcode, lastErr, attempt))
         break;

      DelayForRetry();
   }

   LogMessage("Emir tekrarlı denemelerde başarısız oldu.");
   return(false);
}

bool NeedRetry(const uint retcode,const int lastError,const int attempt)
{
   if(attempt >= MaxOrderRetries - 1)
      return(false);

   if(retcode==TRADE_RETCODE_REQUOTE ||
      retcode==TRADE_RETCODE_REJECT ||
      retcode==TRADE_RETCODE_PRICE_CHANGED ||
      retcode==TRADE_RETCODE_NO_CHANGES ||
      retcode==TRADE_RETCODE_TRADE_CONTEXT_BUSY ||
      retcode==TRADE_RETCODE_TRADE_TIMEOUT ||
      retcode==TRADE_RETCODE_FROZEN ||
      retcode==TRADE_RETCODE_CONNECTION)
      return(true);

   if(lastError==ERR_NO_CONNECTION ||
      lastError==ERR_SERVER_BUSY ||
      lastError==ERR_TRADE_CONTEXT_BUSY ||
      lastError==ERR_PRICE_CHANGED ||
      lastError==ERR_INVALID_PRICE ||
      lastError==ERR_BROKER_BUSY)
      return(true);

   return(false);
}

void DelayForRetry()
{
   if(RetryDelayMilliseconds <= 0)
      return;

   int wait = (int)MathMin((double)RetryDelayMilliseconds, 250.0);
   Sleep(wait);
   RefreshRates();
   (void)UpdateLastTick();
}

double NormalizeVolume(const double volume)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double target = volume;
   if(minVolume > 0 && target < minVolume)
      target = minVolume;

   if(step > 0)
      target = MathFloor(target / step + 0.0000001) * step;

   if(minVolume > 0 && target < minVolume)
      target = minVolume;
   if(maxVolume > 0 && target > maxVolume)
      target = maxVolume;

   long volumeDigits = 2;
   SymbolInfoInteger(_Symbol, SYMBOL_VOLUME_DIGITS, volumeDigits);
   return(NormalizeDouble(target, volumeDigits >= 0 ? (int)volumeDigits : 2));
}

bool ModifyPosition(const ulong ticket,const double sl,const double tp)
{
   if(!trade.PositionModifyByTicket(ticket, sl, tp))
   {
      LogMessage(StringFormat("Pozisyon güncellenemedi (ticket=%llu, err=%d)", ticket, GetLastError()));
      return(false);
   }
   return(true);
}

double findHigh()
{
    double highestHigh = 0;
    for(int i = 0; i < 200; i++)
    {
        double high = iHigh(_Symbol, Timeframe, i);
        if(i > BarsN && iHighest(_Symbol, Timeframe, MODE_HIGH, BarsN*2+1, i-BarsN) == i)
        {
            if(high > highestHigh) return high;
        }
        highestHigh = MathMax(high, highestHigh);
    }
    return -1;
}

double findLow()
{
    double lowestLow = DBL_MAX;
    for(int i = 0; i < 200; i++)
    {
        double low = iLow(_Symbol, Timeframe, i);
        if(i > BarsN && iLowest(_Symbol, Timeframe, MODE_LOW, BarsN*2+1, i-BarsN) == i)
        {
            if(low < lowestLow) return low;
        }
        lowestLow = MathMin(low, lowestLow);
    }
    return -1;
}

void SendBuyOrder(double entry)
{
    double ask = g_lastTick.ask;
    if(ask > entry - OrderDistPoints * _Point) return;

    double tp = entry + Tppoints * _Point;
    double sl = entry - Slpoints * _Point;
    double lots = RiskPercent > 0 ? calcLots(entry - sl) : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    datetime expiration = iTime(_Symbol, Timeframe, 0) + ExpirationBars * PeriodSeconds(Timeframe);
    if(!SendPendingOrder(ORDER_TYPE_BUY_STOP, lots, entry, sl, tp, expiration))
       LogMessage("BuyStop emri gönderilemedi.");
}

void SendSellOrder(double entry)
{
    double bid = g_lastTick.bid;
    if(bid < entry + OrderDistPoints * _Point) return;

    double tp = entry - Tppoints * _Point;
    double sl = entry + Slpoints*_Point;
    double lots = RiskPercent > 0 ? calcLots(sl-entry) : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    datetime expiration = iTime(_Symbol,Timeframe,0) + ExpirationBars * PeriodSeconds(Timeframe);
    if(!SendPendingOrder(ORDER_TYPE_SELL_STOP, lots, entry, sl, tp, expiration))
       LogMessage("SellStop emri gönderilemedi.");
}

double calcLots(double slPoints)
{
    double risk = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
    double ticksize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickvalue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double lotstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minvolume=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxvolume=SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double volumeLimit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);

    if(ticksize <= 0 || tickvalue <= 0 || slPoints <= 0)
    {
        LogMessage("Lot hesaplaması için geçersiz parametre.");
        return(minvolume);
    }

    double moneyPerLotstep = slPoints / ticksize * tickvalue * lotstep;
    if(moneyPerLotstep <= 0)
        return(minvolume);

    double lots = risk / moneyPerLotstep;
    if(volumeLimit!=0) lots = MathMin(lots, volumeLimit);
    if(maxvolume!=0)   lots = MathMin(lots, maxvolume);
    if(minvolume!=0)   lots = MathMax(lots, minvolume);

    return(NormalizeVolume(lots));
}

void CloseAllOrders()
{
    for(int i=OrdersTotal()-1;i>=0;i--)
    {
        if(ord.SelectByIndex(i))
        {
            ulong ticket = ord.Ticket();
            if(ord.Symbol()==_Symbol && ord.Magic()==InpMagic)
            {
               if(!trade.OrderDelete(ticket))
                  LogMessage(StringFormat("Bekleyen emir silinemedi (ticket=%llu, err=%d)", ticket, GetLastError()));
            }
        }
    }
}

void TrailStop()
{
    double sl = 0, tp = 0;
    double ask = g_lastTick.ask;
    double bid = g_lastTick.bid;

    for (int i=PositionsTotal()-1; i>=0; i--)
    {
        if(pos.SelectByIndex(i))
        {
            ulong ticket = pos.Ticket();
            if(pos.Magic()!=InpMagic || pos.Symbol()!=_Symbol) continue;

            if(pos.PositionType()==POSITION_TYPE_BUY)
            {
                if((bid-pos.PriceOpen())>TslTriggerPoints*_Point)
                {
                    tp = pos.TakeProfit();
                    sl = bid - (TslPoints * _Point);
                    if(sl > pos.StopLoss() && sl!=0)
                        ModifyPosition(ticket, sl, tp);
                }
            }
            else if(pos.PositionType()==POSITION_TYPE_SELL)
            {
                if((ask+(TslTriggerPoints*_Point))<pos.PriceOpen())
                {
                    tp = pos.TakeProfit();
                    sl = ask + (TslPoints * _Point);
                    if(sl < pos.StopLoss() && sl!=0)
                        ModifyPosition(ticket, sl, tp);
                }
            }
        }
    }    
}
