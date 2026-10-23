//+------------------------------------------------------------------+
//|                                                  Wizard3_WIN.mq5 |
//|                                                                  |
//|  EA de biblioteca padrao (MQL5 Wizard) enxuto para o WIN.        |
//|                                                                  |
//|  Em vez dos 18 filtros do template, usa 3 de familias            |
//|  diferentes, para que o consenso signifique algo:                |
//|    1. AMA   - tendencia                                          |
//|    2. MACD  - momento                                            |
//|    3. Stoch - timing da entrada                                  |
//|                                                                  |
//|  Acrescenta ao template o que ele nao tem e o WIN exige:         |
//|    - magic e EveryTick como input (varios robos no mesmo ativo)  |
//|    - janela de entradas e horario de zerar                       |
//|    - limite de perda do dia, de operacoes e de perdas seguidas   |
//|    - entrada por limitada via PriceLevel, com validade em barras |
//|                                                                  |
//|  Conta netting (B3): trata uma posicao por simbolo.              |
//|                                                                  |
//|  v1.00 - primeira versao                                         |
//+------------------------------------------------------------------+
#property copyright "maikon arruda"
#property version   "1.00"
#property description "Wizard enxuto para WIN: AMA + MACD + Estocastico, com horario e limites do dia"

#include <Expert\Expert.mqh>
#include <Expert\Signal\SignalAMA.mqh>
#include <Expert\Signal\SignalMACD.mqh>
#include <Expert\Signal\SignalStoch.mqh>
#include <Expert\Trailing\TrailingFixedPips.mqh>
#include <Expert\Trailing\TrailingNone.mqh>
#include <Expert\Money\MoneyFixedLot.mqh>
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "Geral"
input ulong  InpMagic           = 777001;   // Numero magico (unico por robo)
input bool   InpEveryTick       = false;    // true = avalia a cada tick | false = no fechamento da barra
input double InpLotes           = 1.0;      // Contratos por entrada

input group "Consenso dos 3 filtros"
input int    InpThresholdOpen   = 50;       // Forca minima para abrir [0...100]
input int    InpThresholdClose  = 30;       // Forca minima para fechar [0...100]
input double InpPesoAMA         = 1.0;      // Peso da AMA (tendencia) [0...1]
input double InpPesoMACD        = 1.0;      // Peso do MACD (momento) [0...1]
input double InpPesoStoch       = 1.0;      // Peso do Estocastico (timing) [0...1]

input group "Entrada"
input int    InpOffsetLimite    = 100;      // 0 = a mercado | >0 = limitada N pontos melhor
input int    InpValidade        = 3;        // Validade da limitada (barras)
input bool   InpInverterSinal   = false;    // Se a limitada nascer do lado errado, marque aqui

input group "Stop e alvo"
input int    InpStopPoints      = 125;      // Stop (pontos)
input int    InpTakePoints      = 250;      // Alvo (pontos)

input group "Trailing"
input bool   InpUsarTrailing    = true;     // Ligar trailing stop
input int    InpTrailStop       = 125;      // Distancia do stop ao preco (pontos)
input int    InpTrailProfit     = 0;        // 0 = mantem o alvo fixo

input group "AMA (tendencia)"
input int    InpAMAPeriodo      = 10;       // Periodo de media
input int    InpAMAFast         = 2;        // EMA rapida
input int    InpAMASlow         = 30;       // EMA lenta

input group "MACD (momento)"
input int    InpMACDFast        = 12;       // EMA rapida
input int    InpMACDSlow        = 24;       // EMA lenta
input int    InpMACDSignal      = 9;        // Media da diferenca

input group "Estocastico (timing)"
input int    InpStochK          = 8;        // Periodo K
input int    InpStochD          = 3;        // Periodo D
input int    InpStochSlow       = 3;        // Suavizacao

input group "Horario (hora do servidor)"
input string InpInicio          = "09:15";  // Inicio das entradas
input string InpFimEntradas     = "17:15";  // Fim das entradas
input string InpZerar           = "17:50";  // Hora de zerar tudo

input group "Limites do dia"
input int    InpMaxOperacoes    = 6;        // Maximo de entradas por dia (0 = sem limite)
input double InpPerdaMaxDia     = 300;      // Perda maxima do dia em R$ (0 = sem limite)
input int    InpPerdasSeguidas  = 3;        // Para no dia apos N perdas seguidas (0 = nao)

//+------------------------------------------------------------------+
//| Globais                                                          |
//+------------------------------------------------------------------+
CExpert         ExtExpert;
CExpertSignal  *ExtSignal = NULL;
CTrade          ExtTrade;

int      gIni    = 0;          // inicio das entradas, em minutos do dia
int      gFim    = 0;          // fim das entradas
int      gZerar  = 0;          // hora de zerar
datetime gDiaRef = 0;          // data do dia corrente
bool     gBloqDia = false;     // dia bloqueado por algum limite
datetime gUltApura = 0;        // ultima apuracao do dia

//+------------------------------------------------------------------+
//| "09:15" -> minutos do dia                                        |
//+------------------------------------------------------------------+
int MinutosDe(const string hhmm)
  {
   string partes[];
   if(StringSplit(hhmm, (ushort)':', partes) != 2)
      return(-1);
   int h = (int)StringToInteger(partes[0]);
   int m = (int)StringToInteger(partes[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return(-1);
   return(h * 60 + m);
  }

//+------------------------------------------------------------------+
//| Apura o dia: perda, numero de entradas e perdas seguidas         |
//+------------------------------------------------------------------+
void ApurarDia()
  {
   //--- no maximo uma apuracao a cada 5 segundos
   if(TimeCurrent() - gUltApura < 5)
      return;
   gUltApura = TimeCurrent();

   if(!HistorySelect(gDiaRef, TimeCurrent() + 60))
      return;

   double lucro    = 0.0;
   int    entradas = 0;
   int    seguidas = 0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      if((ulong)HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol)
         continue;

      double p = HistoryDealGetDouble(t, DEAL_PROFIT)
               + HistoryDealGetDouble(t, DEAL_SWAP)
               + HistoryDealGetDouble(t, DEAL_COMMISSION);
      lucro += p;

      long entry = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
         entradas++;
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
        {
         if(p < 0.0)
            seguidas++;
         else
            seguidas = 0;
        }
     }

   if(InpPerdaMaxDia > 0 && lucro <= -InpPerdaMaxDia)
      gBloqDia = true;
   if(InpMaxOperacoes > 0 && entradas >= InpMaxOperacoes)
      gBloqDia = true;
   if(InpPerdasSeguidas > 0 && seguidas >= InpPerdasSeguidas)
      gBloqDia = true;
  }

//+------------------------------------------------------------------+
//| Cancela as ordens pendentes deste robo                           |
//+------------------------------------------------------------------+
void CancelarPendentes()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      ExtTrade.OrderDelete(t);
     }
  }

//+------------------------------------------------------------------+
//| Fecha a posicao deste robo                                       |
//+------------------------------------------------------------------+
void FecharPosicao()
  {
   if(!PositionSelect(_Symbol))
      return;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return;
   ExtTrade.PositionClose(_Symbol);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   gIni   = MinutosDe(InpInicio);
   gFim   = MinutosDe(InpFimEntradas);
   gZerar = MinutosDe(InpZerar);
   if(gIni < 0 || gFim < 0 || gZerar < 0)
     {
      printf(__FUNCTION__ + ": horario invalido, use o formato HH:MM");
      return(INIT_PARAMETERS_INCORRECT);
     }

   ExtTrade.SetExpertMagicNumber(InpMagic);
   ExtTrade.SetMarginMode();
   ExtTrade.LogLevel(LOG_LEVEL_ERRORS);

   if(!ExtExpert.Init(_Symbol, _Period, InpEveryTick, InpMagic))
     {
      printf(__FUNCTION__ + ": erro ao inicializar o expert");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }

   //--- objeto de sinal
   ExtSignal = new CExpertSignal;
   if(ExtSignal == NULL)
     {
      printf(__FUNCTION__ + ": erro ao criar o sinal");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }
   if(!ExtExpert.InitSignal(ExtSignal))
     {
      printf(__FUNCTION__ + ": erro ao inicializar o sinal");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }

   ExtSignal.ThresholdOpen(InpThresholdOpen);
   ExtSignal.ThresholdClose(InpThresholdClose);
   ExtSignal.StopLevel((double)InpStopPoints);
   ExtSignal.TakeLevel((double)InpTakePoints);
   ExtSignal.Expiration(InpValidade);

   //--- PriceLevel: a biblioteca calcula o preco como
   //--- base - PriceLevel x unidade, logo POSITIVO = preco melhor
   //--- que o mercado, ou seja ordem limitada. InpInverterSinal
   //--- troca o sinal sem recompilar, caso a ordem nasca do lado
   //--- errado neste build do terminal.
   double nivel = (double)InpOffsetLimite;
   if(InpInverterSinal)
      nivel = -nivel;
   ExtSignal.PriceLevel(nivel);

   //--- filtro 1: tendencia
   CSignalAMA *f1 = new CSignalAMA;
   if(f1 == NULL)
     {
      printf(__FUNCTION__ + ": erro ao criar o filtro AMA");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }
   ExtSignal.AddFilter(f1);
   f1.PeriodMA(InpAMAPeriodo);
   f1.PeriodFast(InpAMAFast);
   f1.PeriodSlow(InpAMASlow);
   f1.Applied(PRICE_CLOSE);
   f1.Weight(InpPesoAMA);

   //--- filtro 2: momento
   CSignalMACD *f2 = new CSignalMACD;
   if(f2 == NULL)
     {
      printf(__FUNCTION__ + ": erro ao criar o filtro MACD");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }
   ExtSignal.AddFilter(f2);
   f2.PeriodFast(InpMACDFast);
   f2.PeriodSlow(InpMACDSlow);
   f2.PeriodSignal(InpMACDSignal);
   f2.Applied(PRICE_CLOSE);
   f2.Weight(InpPesoMACD);

   //--- filtro 3: timing
   CSignalStoch *f3 = new CSignalStoch;
   if(f3 == NULL)
     {
      printf(__FUNCTION__ + ": erro ao criar o filtro Estocastico");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }
   ExtSignal.AddFilter(f3);
   f3.PeriodK(InpStochK);
   f3.PeriodD(InpStochD);
   f3.PeriodSlow(InpStochSlow);
   f3.Applied(STO_LOWHIGH);
   f3.Weight(InpPesoStoch);

   //--- trailing
   if(InpUsarTrailing)
     {
      CTrailingFixedPips *tr = new CTrailingFixedPips;
      if(tr == NULL)
        {
         printf(__FUNCTION__ + ": erro ao criar o trailing");
         ExtExpert.Deinit();
         return(INIT_FAILED);
        }
      if(!ExtExpert.InitTrailing(tr))
        {
         printf(__FUNCTION__ + ": erro ao inicializar o trailing");
         ExtExpert.Deinit();
         return(INIT_FAILED);
        }
      tr.StopLevel(InpTrailStop);
      tr.ProfitLevel(InpTrailProfit);
     }
   else
     {
      CTrailingNone *tr = new CTrailingNone;
      if(tr == NULL || !ExtExpert.InitTrailing(tr))
        {
         printf(__FUNCTION__ + ": erro ao inicializar o trailing");
         ExtExpert.Deinit();
         return(INIT_FAILED);
        }
     }

   //--- volume
   CMoneyFixedLot *mm = new CMoneyFixedLot;
   if(mm == NULL)
     {
      printf(__FUNCTION__ + ": erro ao criar o money management");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }
   if(!ExtExpert.InitMoney(mm))
     {
      printf(__FUNCTION__ + ": erro ao inicializar o money management");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }
   mm.Lots(InpLotes);

   if(!ExtExpert.ValidationSettings())
     {
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }
   if(!ExtExpert.InitIndicators())
     {
      printf(__FUNCTION__ + ": erro ao inicializar os indicadores");
      ExtExpert.Deinit();
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ExtExpert.Deinit();
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int agora = dt.hour * 60 + dt.min;

   //--- virada de dia: solta o bloqueio
   datetime hoje = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(hoje != gDiaRef)
     {
      gDiaRef   = hoje;
      gBloqDia  = false;
      gUltApura = 0;
     }

   ApurarDia();

   //--- hora de zerar: cancela, fecha e nao avalia mais nada
   if(agora >= gZerar)
     {
      CancelarPendentes();
      FecharPosicao();
      return;
     }

   bool podeEntrar = (!gBloqDia) && (agora >= gIni) && (agora < gFim);

   //--- fora da janela, threshold 101 nao e alcancavel: o expert
   //--- continua administrando a posicao mas nao abre nenhuma nova
   if(ExtSignal != NULL)
      ExtSignal.ThresholdOpen(podeEntrar ? InpThresholdOpen : 101);

   if(!podeEntrar)
      CancelarPendentes();

   ExtExpert.OnTick();
  }

//+------------------------------------------------------------------+
//| OnTrade                                                          |
//+------------------------------------------------------------------+
void OnTrade()
  {
   ExtExpert.OnTrade();
  }

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//+------------------------------------------------------------------+
void OnTimer()
  {
   ExtExpert.OnTimer();
  }
//+------------------------------------------------------------------+
