//+------------------------------------------------------------------+
//|                                       Delta_Fluxo_WIN.mq5        |
//|                                                                   |
//|  Estrategia de DIVERGENCIA DE DELTA para WIN (B3).                |
//|                                                                   |
//|  Delta = volume agredido na compra menos volume agredido na venda, |
//|  lido dos ticks reais via TICK_FLAG_BUY / TICK_FLAG_SELL.          |
//|                                                                   |
//|  Divergencia de baixa: preco faz topo mais ALTO, mas o delta       |
//|  acumulado faz topo mais BAIXO -> a alta nao teve agressao         |
//|  compradora proporcional -> vende.                                 |
//|                                                                   |
//|  Divergencia de alta: preco faz fundo mais BAIXO, delta acumulado  |
//|  faz fundo mais ALTO -> compra.                                    |
//|                                                                   |
//|  IMPORTANTE: no testador, use "cada tick com base em ticks reais". |
//|  Nos outros modos as flags nao existem e o delta sai zerado.       |
//+------------------------------------------------------------------+
#property copyright "Maikon"
#property version   "1.01"   // v1.01: offset da limite padrao = 300 pontos
#property strict

#include <Trade\Trade.mqh>

//--- Sinais ativos
input bool   InpUsarDivergencia = true;  // Sinal 1: divergencia de delta (dois pivos)
input bool   InpUsarAbsorcao    = true;  // Sinal 2: absorcao (uma barra)

//--- Absorcao: muita agressao, pouco movimento
input long   InpDeltaMinimo    = 400;  // Delta minimo da barra (contratos, em modulo)
input int    InpRangeMaximo    = 60;   // Range maximo da barra (pontos)

//--- Deteccao de pivo (divergencia)
input int    InpLookback       = 60;   // Barras analisadas em busca de pivos
input int    InpPivotK         = 2;    // Barras de cada lado que definem um pivo
input int    InpMaxPivotAge    = 5;    // Idade maxima do pivo recente (barras)

//--- Forca minima da divergencia
input double InpMinPriceDiff   = 30;   // Diferenca minima entre os dois topos/fundos (pontos)
input long   InpMinDeltaDiff   = 200;  // Diferenca minima entre os dois deltas (contratos)

//--- Ordem
input bool   InpUsarLimite     = true; // Entrar por ordem limite (false = a mercado)
input int    InpLimitOffset    = 300;  // Distancia da limite ate o preco atual (pontos)
input int    InpOrderValidBars = 2;    // Barras de validade da ordem limite
input double InpLots           = 1.0;  // Contratos por operacao
input int    InpStopPoints     = 125;  // Stop em pontos
input int    InpTakePoints     = 125;  // Alvo em pontos

//--- Filtro de TENDENCIA: so opera a favor da media
input bool            InpUsarFiltroTend = true;        // Operar apenas a favor da tendencia
input ENUM_TIMEFRAMES InpTFTendencia    = PERIOD_M15;  // Timeframe da media de tendencia
input int             InpMAPeriodo      = 50;          // Periodo da media
input ENUM_MA_METHOD  InpMAMetodo       = MODE_EMA;    // Metodo da media
input int             InpMADistMin      = 50;          // Distancia minima do preco ate a media (pontos)

//--- Filtro de horario
input bool   InpUseTimeFilter  = true; // Ativar filtro de horario
input int    InpStartHour      = 9;    // Hora inicial (servidor)
input int    InpEndHour        = 17;   // Hora final (servidor)

//--- Controle de frequencia
input int    InpMinBarsEntre   = 10;   // Barras minimas entre uma entrada e a proxima

//--- Operacional
input int    InpMagic          = 999;
input int    InpSlippage       = 20;
input bool   InpLog            = true; // Registrar divergencias no log

//+------------------------------------------------------------------+
//| CANCELAR A LIMITE POR AGRESSAO CONTRA                             |
//| Enquanto existe ordem limite pendente, le uma vez por segundo os   |
//| ultimos InpRajJanelaSeg segundos de negocios. Se vier uma rajada   |
//| dominada CONTRA o lado da ordem, cancela a ordem. So isso: nao     |
//| mexe em posicao aberta.                                           |
//+------------------------------------------------------------------+
input group "Cancelar a limite por agressao contra"
input bool   InpRajUsar       = true;   // Ligar a regra
input int    InpRajJanelaSeg  = 10;     // Janela de leitura (segundos)
input double InpRajFator      = 3.0;    // Volume da janela >= fator x volume normal
input double InpRajDominioPct = 75;     // % do volume agredido de um lado
input int    InpRajNiveis     = 22;     // Niveis (ticks) que o preco andou contra (22 x 5 = 110 pts)
input int    InpRajMediaN     = 30;     // Barras M1 para medir o volume normal

//--- estado da regra de cancelamento por agressao
double   g_rajFator  = 0.0;   // ultima leitura, em x o volume normal
datetime g_rajUltSeg = 0;     // leitura no maximo 1x por segundo

//+------------------------------------------------------------------+
CTrade   trade;
datetime lastBarTime = 0;
int      hMA = INVALID_HANDLE;

//--- memoria do ultimo sinal: evita repetir a MESMA divergencia
datetime ultimoPivoTopo  = 0;
datetime ultimoPivoFundo = 0;
datetime horaUltimaEntrada = 0;

//--- cache de delta por barra. Indice 0 = ultima barra FECHADA.
long     deltaBar[];      // delta da barra
long     deltaCum[];      // delta acumulado ate aquela barra
datetime barTimeCache[];  // hora de abertura da barra (para validar o cache)
int      cacheSize = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(!InpUsarDivergencia && !InpUsarAbsorcao)
   {
      Print("Nenhum sinal ativo: ligue divergencia, absorcao ou os dois");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpLookback < 20 || InpPivotK < 1)
   {
      Print("Lookback deve ser >= 20 e PivotK >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   PrintFormat("Sinais: divergencia=%s | absorcao=%s (delta>=%d, range<=%d pts)",
               InpUsarDivergencia ? "ON" : "OFF",
               InpUsarAbsorcao    ? "ON" : "OFF",
               (int)InpDeltaMinimo, InpRangeMaximo);
   if(InpStopPoints <= 0 || InpTakePoints <= 0)
   {
      Print("Stop e alvo devem ser maiores que zero");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTakePoints < InpStopPoints)
      PrintFormat("Atencao: risco/retorno negativo (stop %d x alvo %d). "
                  "Exige acerto acima de %.1f%% so para empatar.",
                  InpStopPoints, InpTakePoints,
                  100.0 * InpStopPoints / (InpStopPoints + InpTakePoints));

   if(InpUsarLimite)
   {
      if(InpOrderValidBars < 1 || InpLimitOffset <= 0)
      {
         Print("Offset e validade da ordem limite devem ser maiores que zero");
         return INIT_PARAMETERS_INCORRECT;
      }
      PrintFormat("Entrada por LIMITE | offset %d pontos | validade %d barras | stop %d | alvo %d",
                  InpLimitOffset, InpOrderValidBars, InpStopPoints, InpTakePoints);
   }
   else
      PrintFormat("Entrada a MERCADO | stop %d | alvo %d", InpStopPoints, InpTakePoints);

   if(InpUsarFiltroTend)
   {
      hMA = iMA(_Symbol, InpTFTendencia, InpMAPeriodo, 0, InpMAMetodo, PRICE_CLOSE);
      if(hMA == INVALID_HANDLE)
      {
         Print("Falha ao criar a media de tendencia");
         return INIT_FAILED;
      }
      PrintFormat("Filtro de tendencia: %s(%d) em %s | zona neutra de %d pontos",
                  EnumToString(InpMAMetodo), InpMAPeriodo,
                  EnumToString(InpTFTendencia), InpMADistMin);
   }
   else
      Print("Filtro de tendencia DESLIGADO - opera nos dois sentidos");

   cacheSize = InpLookback + InpPivotK + 5;
   ArrayResize(deltaBar,     cacheSize);
   ArrayResize(deltaCum,     cacheSize);
   ArrayResize(barTimeCache, cacheSize);
   ArrayInitialize(deltaBar, 0);
   ArrayInitialize(deltaCum, 0);
   for(int i = 0; i < cacheSize; i++) barTimeCache[i] = 0;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hMA != INVALID_HANDLE) IndicatorRelease(hMA);
}

//+------------------------------------------------------------------+
//| TENDENCIA                                                        |
//| +1 alta, -1 baixa, 0 indefinida (preco colado na media)          |
//+------------------------------------------------------------------+
int Tendencia()
{
   if(!InpUsarFiltroTend) return 0;

   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(hMA, 0, 0, 1, ma) < 1) return 0;
   if(ma[0] <= 0.0) return 0;

   double preco = iClose(_Symbol, InpTFTendencia, 0);
   if(preco <= 0.0) return 0;

   double dist = preco - ma[0];

   //--- zona neutra: perto demais da media, tendencia indefinida
   if(MathAbs(dist) < InpMADistMin * _Point) return 0;

   return (dist > 0.0) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| DELTA DE UMA BARRA                                               |
//| Le os negocios (COPY_TICKS_TRADE) da janela da barra e soma o     |
//| volume conforme o lado do agressor.                               |
//+------------------------------------------------------------------+
long BarDelta(datetime barStart)
{
   MqlTick ticks[];
   ulong de  = (ulong)barStart * 1000;
   ulong ate = de + (ulong)PeriodSeconds(PERIOD_M1) * 1000 - 1;

   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, de, ate);
   if(n <= 0) return 0;

   long d = 0;
   for(int i = 0; i < n; i++)
   {
      bool compra = (ticks[i].flags & TICK_FLAG_BUY)  != 0;
      bool venda  = (ticks[i].flags & TICK_FLAG_SELL) != 0;

      // negocio que fecha os dois lados: nao atribui agressor, ignora
      if(compra == venda) continue;

      long v = (long)ticks[i].volume;
      if(v <= 0) continue;

      d += compra ? v : -v;
   }
   return d;
}

//+------------------------------------------------------------------+
//| Atualiza o cache: calcula apenas a barra nova e desloca o resto.  |
//+------------------------------------------------------------------+
bool AtualizarCache()
{
   datetime t1 = iTime(_Symbol, PERIOD_M1, 1);   // ultima barra fechada
   if(t1 <= 0) return false;

   //--- ja esta em dia?
   if(barTimeCache[0] == t1) return true;

   //--- cache vazio ou muito defasado: reconstroi tudo
   if(barTimeCache[0] == 0 || iBarShift(_Symbol, PERIOD_M1, barTimeCache[0]) >= cacheSize - 1)
   {
      for(int i = 0; i < cacheSize; i++)
      {
         datetime bt = iTime(_Symbol, PERIOD_M1, i + 1);
         if(bt <= 0) return false;
         barTimeCache[i] = bt;
         deltaBar[i]     = BarDelta(bt);
      }
   }
   else
   {
      //--- caso normal: entrou 1 barra nova, desloca e calcula so ela
      int passos = iBarShift(_Symbol, PERIOD_M1, barTimeCache[0]) - 1;
      if(passos < 1) passos = 1;

      for(int p = 0; p < passos; p++)
      {
         for(int i = cacheSize - 1; i > 0; i--)
         {
            deltaBar[i]     = deltaBar[i - 1];
            barTimeCache[i] = barTimeCache[i - 1];
         }
         datetime bt = iTime(_Symbol, PERIOD_M1, passos - p);
         barTimeCache[0] = bt;
         deltaBar[0]     = BarDelta(bt);
      }
   }

   //--- delta acumulado: soma do mais antigo ate cada barra
   long soma = 0;
   for(int i = cacheSize - 1; i >= 0; i--)
   {
      soma += deltaBar[i];
      deltaCum[i] = soma;
   }
   return true;
}

//+------------------------------------------------------------------+
//| PIVOS                                                            |
//| Barra i e topo se sua maxima supera as K barras de cada lado.     |
//| O indice i e o shift em relacao a barra atual (1 = ultima fechada)|
//+------------------------------------------------------------------+
bool EhTopo(int shift, int k)
{
   double h = iHigh(_Symbol, PERIOD_M1, shift);
   for(int j = 1; j <= k; j++)
   {
      if(iHigh(_Symbol, PERIOD_M1, shift - j) >= h) return false;  // lado direito
      if(iHigh(_Symbol, PERIOD_M1, shift + j) >  h) return false;  // lado esquerdo
   }
   return true;
}

bool EhFundo(int shift, int k)
{
   double l = iLow(_Symbol, PERIOD_M1, shift);
   for(int j = 1; j <= k; j++)
   {
      if(iLow(_Symbol, PERIOD_M1, shift - j) <= l) return false;
      if(iLow(_Symbol, PERIOD_M1, shift + j) >= l) return false;
   }
   return true;
}

//--- devolve os shifts dos dois pivos mais recentes; false se nao achar
bool DoisTopos(int &recente, int &anterior)
{
   recente = anterior = -1;
   // comeca em PivotK+1: um pivo precisa de K barras a direita ja fechadas
   for(int s = InpPivotK + 1; s <= InpLookback; s++)
   {
      if(!EhTopo(s, InpPivotK)) continue;
      if(recente < 0)       recente  = s;
      else                { anterior = s; return true; }
   }
   return false;
}

bool DoisFundos(int &recente, int &anterior)
{
   recente = anterior = -1;
   for(int s = InpPivotK + 1; s <= InpLookback; s++)
   {
      if(!EhFundo(s, InpPivotK)) continue;
      if(recente < 0)       recente  = s;
      else                { anterior = s; return true; }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Utilitarios                                                      |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t != lastBarTime) { lastBarTime = t; return true; }
   return false;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//--- ordem pendente deste EA neste simbolo
bool HasPendingOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderGetTicket(i) == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//--- cancela a limite que passou da validade
void CancelExpiredOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      datetime criada = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      int barras = Bars(_Symbol, PERIOD_M1, criada, TimeCurrent()) - 1;
      if(barras >= InpOrderValidBars)
      {
         trade.OrderDelete(ticket);
         if(InpLog)
            PrintFormat("Limite cancelada: %d barras sem execucao", InpOrderValidBars);
      }
   }
}

//--- cancela qualquer pendente deste EA
void CancelAllOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == InpMagic)
         trade.OrderDelete(ticket);
   }
}

bool TimeAllowed()
{
   if(!InpUseTimeFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour <= InpEndHour)
      return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
   return (dt.hour >= InpStartHour || dt.hour < InpEndHour);
}

double NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) return NormalizeDouble(price, _Digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

double CalcLots()
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0.0) lotStep = 1.0;
   int digitsLot = (lotStep >= 1.0) ? 0 : 2;
   return NormalizeDouble(MathMin(MathMax(InpLots, minLot), maxLot), digitsLot);
}


//+------------------------------------------------------------------+
//| trade.OrderDelete(t) A LIMITE POR AGRESSAO CONTRA                             |
//+------------------------------------------------------------------+
double RajTickSz()
{
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return (t > 0.0) ? t : _Point;
}

double RajVolTick(const MqlTick &t)
{
   return (t.volume_real > 0.0) ? t.volume_real : (double)t.volume;
}

double RajVolBar(const MqlRates &r)
{
   return (r.real_volume > 0) ? (double)r.real_volume : (double)r.tick_volume;
}

//--- direcao da ordem pendente deste EA: +1 compra, -1 venda, 0 nenhuma
int RajOrdemPendente(ulong &ticket)
{
   ticket = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagic) continue;
      ticket = t;
      ENUM_ORDER_TYPE tp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      return (tp == ORDER_TYPE_BUY_LIMIT || tp == ORDER_TYPE_BUY_STOP ||
              tp == ORDER_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

//--- agressao dos ultimos InpRajJanelaSeg segundos ate agora: +1, -1 ou 0
int RajadaAgora(double &fator)
{
   fator = 0.0;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, InpRajMediaN, r) < InpRajMediaN) return 0;
   double soma = 0.0;
   for(int k = 0; k < InpRajMediaN; k++) soma += RajVolBar(r[k]);
   double volNormal = soma / InpRajMediaN;            // volume de uma barra M1
   if(volNormal <= 0.0) return 0;
   double volJanela = volNormal * InpRajJanelaSeg / 60.0;
   if(volJanela <= 0.0) return 0;

   MqlTick tk[];
   ulong ate = (ulong)TimeCurrent() * 1000 + 999;
   ulong de  = ate - (ulong)InpRajJanelaSeg * 1000;
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE, de, ate);
   if(n < 2) return 0;

   //--- lado agressor: flags da bolsa; sem elas, regra do tick
   bool temFlags = false;
   for(int i = 0; i < n && !temFlags; i++)
      if((tk[i].flags & (TICK_FLAG_BUY | TICK_FLAG_SELL)) != 0) temFlags = true;

   double vc = 0.0, vv = 0.0;
   double p0 = tk[0].last, mx = p0, mn = p0;
   int    ultimo = 0;
   for(int i = 0; i < n; i++)
   {
      int l = 0;
      if(temFlags)
      {
         bool b = (tk[i].flags & TICK_FLAG_BUY)  != 0;
         bool v = (tk[i].flags & TICK_FLAG_SELL) != 0;
         l = (b && !v) ? 1 : (v && !b) ? -1 : 0;
      }
      else if(i > 0)
      {
         l = (tk[i].last > tk[i-1].last) ? 1 : (tk[i].last < tk[i-1].last) ? -1 : ultimo;
         ultimo = l;
      }
      double vol = RajVolTick(tk[i]);
      if(l > 0) vc += vol;
      if(l < 0) vv += vol;
      if(tk[i].last > 0.0)
      {
         mx = MathMax(mx, tk[i].last);
         mn = MathMin(mn, tk[i].last);
      }
   }

   double total = vc + vv;
   fator = total / volJanela;
   if(total <= 0.0 || total < InpRajFator * volJanela) return 0;

   double niveis = InpRajNiveis * RajTickSz();
   if(vc >= InpRajDominioPct / 100.0 * total && mx - p0 >= niveis - RajTickSz() / 2) return  1;
   if(vv >= InpRajDominioPct / 100.0 * total && p0 - mn >= niveis - RajTickSz() / 2) return -1;
   return 0;
}

//--- rajada contra a ordem pendente: cancela a ordem, e so isso
void CancelarPorRajada()
{
   if(!InpRajUsar) return;

   ulong t = 0;
   int dir = RajOrdemPendente(t);
   if(dir == 0) { g_rajFator = 0.0; return; }

   datetime agora = TimeCurrent();
   if(agora == g_rajUltSeg) return;
   g_rajUltSeg = agora;

   int ag = RajadaAgora(g_rajFator);
   if(ag == 0 || ag != -dir) return;

   if(trade.OrderDelete(t))
      PrintFormat("Limite de %s cancelada: agressao %s de %.1fx o volume contra ela",
                  (dir > 0 ? "compra" : "venda"),
                  (ag > 0 ? "de compra" : "de venda"), g_rajFator);
}

//+------------------------------------------------------------------+
//| LOGICA PRINCIPAL                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- roda a cada tick: a rajada e evento de segundos, nao de barra
   CancelarPorRajada();

   if(!IsNewBar()) return;

   //--- posicao aberta: limpa pendencias e espera
   if(HasOpenPosition())
   {
      if(InpUsarLimite) CancelAllOrders();
      return;
   }

   //--- gerencia validade da limite antes de procurar sinal novo
   if(InpUsarLimite)
   {
      CancelExpiredOrders();
      if(HasPendingOrder()) return;
   }

   if(!TimeAllowed()) return;

   //--- intervalo minimo desde a ultima entrada
   if(InpMinBarsEntre > 0 && horaUltimaEntrada > 0)
   {
      int barras = Bars(_Symbol, PERIOD_M1, horaUltimaEntrada, TimeCurrent()) - 1;
      if(barras < InpMinBarsEntre) return;
   }

   if(!AtualizarCache()) return;

   //--- avalia os dois sinais
   int sDiv = InpUsarDivergencia ? SinalDivergencia() : 0;
   int sAbs = InpUsarAbsorcao    ? SinalAbsorcao()    : 0;

   if(sDiv == 0 && sAbs == 0) return;

   //--- sinais em direcoes opostas: nao opera
   if(sDiv != 0 && sAbs != 0 && sDiv != sAbs)
   {
      if(InpLog) Print("Sinais conflitantes (divergencia x absorcao) - nada feito");
      return;
   }

   int direcao = (sDiv != 0) ? sDiv : sAbs;

   //--- filtro de tendencia: so opera a favor
   if(InpUsarFiltroTend)
   {
      int tend = Tendencia();
      if(tend == 0)
      {
         if(InpLog) Print("Tendencia indefinida (preco colado na media) - nada feito");
         return;
      }
      if(direcao != tend)
      {
         if(InpLog)
            PrintFormat("Sinal %s contra a tendencia %s - descartado",
                        direcao > 0 ? "COMPRA" : "VENDA",
                        tend    > 0 ? "de ALTA" : "de BAIXA");
         return;
      }
   }

   //--- confirma o pivo so agora, quando a entrada vai de fato acontecer
   if(sDiv != 0) MarcarPivoUsado(sDiv);

   Entrar(direcao > 0);
}

//+------------------------------------------------------------------+
//| SINAL 1 - DIVERGENCIA DE DELTA                                   |
//| +1 compra, -1 venda, 0 nada                                      |
//+------------------------------------------------------------------+
int SinalDivergencia()
{
   int r, a;

   //--- DIVERGENCIA DE BAIXA: topo maior no preco, topo menor no delta
   if(DoisTopos(r, a) && r <= InpMaxPivotAge + InpPivotK)
   {
      double pRec = iHigh(_Symbol, PERIOD_M1, r);
      double pAnt = iHigh(_Symbol, PERIOD_M1, a);
      long   dRec = deltaCum[r - 1];        // cache: indice 0 = shift 1
      long   dAnt = deltaCum[a - 1];

      bool precoSubiu = (pRec - pAnt) >= InpMinPriceDiff * _Point;
      bool deltaCaiu  = (dAnt - dRec) >= InpMinDeltaDiff;

      if(precoSubiu && deltaCaiu && iTime(_Symbol, PERIOD_M1, r) != ultimoPivoTopo)
      {
         if(InpLog)
            PrintFormat("DIV BAIXA | topo %.0f>%.0f (+%.0f pts) | delta %d<%d (-%d)",
                        pRec, pAnt, (pRec - pAnt) / _Point,
                        (int)dRec, (int)dAnt, (int)(dAnt - dRec));
         return -1;
      }
   }

   //--- DIVERGENCIA DE ALTA: fundo menor no preco, fundo maior no delta
   if(DoisFundos(r, a) && r <= InpMaxPivotAge + InpPivotK)
   {
      double pRec = iLow(_Symbol, PERIOD_M1, r);
      double pAnt = iLow(_Symbol, PERIOD_M1, a);
      long   dRec = deltaCum[r - 1];
      long   dAnt = deltaCum[a - 1];

      bool precoCaiu  = (pAnt - pRec) >= InpMinPriceDiff * _Point;
      bool deltaSubiu = (dRec - dAnt) >= InpMinDeltaDiff;

      if(precoCaiu && deltaSubiu && iTime(_Symbol, PERIOD_M1, r) != ultimoPivoFundo)
      {
         if(InpLog)
            PrintFormat("DIV ALTA | fundo %.0f<%.0f (-%.0f pts) | delta %d>%d (+%d)",
                        pRec, pAnt, (pAnt - pRec) / _Point,
                        (int)dRec, (int)dAnt, (int)(dRec - dAnt));
         return 1;
      }
   }

   return 0;
}

//--- marca o pivo como usado para nao repetir a mesma divergencia
void MarcarPivoUsado(int direcao)
{
   int r, a;
   if(direcao < 0 && DoisTopos(r, a))  ultimoPivoTopo  = iTime(_Symbol, PERIOD_M1, r);
   if(direcao > 0 && DoisFundos(r, a)) ultimoPivoFundo = iTime(_Symbol, PERIOD_M1, r);
}

//+------------------------------------------------------------------+
//| SINAL 2 - ABSORCAO                                               |
//| Muita agressao numa barra que quase nao andou.                   |
//| Entra CONTRA quem agrediu.                                       |
//+------------------------------------------------------------------+
int SinalAbsorcao()
{
   long   d     = deltaBar[0];   // ultima barra fechada
   double range = iHigh(_Symbol, PERIOD_M1, 1) - iLow(_Symbol, PERIOD_M1, 1);

   bool agressaoForte = (MathAbs(d) >= InpDeltaMinimo);
   bool precoParado   = (range <= InpRangeMaximo * _Point);

   if(!agressaoForte || !precoParado) return 0;

   if(InpLog)
      PrintFormat("ABSORCAO | delta %d | range %.0f pts -> entra %s",
                  (int)d, range / _Point, (d > 0) ? "VENDIDO" : "COMPRADO");

   // delta positivo (compraram) e o preco nao subiu -> vendedor grande absorvendo -> vende
   return (d > 0) ? -1 : 1;
}

//+------------------------------------------------------------------+
void Entrar(bool isLong)
{
   double risk   = InpStopPoints * _Point;
   double reward = InpTakePoints * _Point;

   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(risk < minStop || reward < minStop)
   {
      PrintFormat("Stop/alvo abaixo do minimo da corretora (%.0f pontos) - ignorada",
                  minStop / _Point);
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- cotacao invalida: sem isso o preco da ordem sai a partir do zero
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
   {
      PrintFormat("Cotacao indisponivel (ask=%.0f bid=%.0f) - entrada ignorada", ask, bid);
      return;
   }

   double lots = CalcLots();
   bool ok = false;

   if(InpUsarLimite)
   {
      //--- limite na direcao favoravel: compra ABAIXO, venda ACIMA
      double preco = isLong ? ask - InpLimitOffset * _Point
                            : bid + InpLimitOffset * _Point;
      preco = NormalizePrice(preco);

      double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(isLong && preco >= ask - stopLevel)
      {
         if(InpLog) PrintFormat("Limite de compra em %.0f nao cabe abaixo do ask %.0f", preco, ask);
         return;
      }
      if(!isLong && preco <= bid + stopLevel)
      {
         if(InpLog) PrintFormat("Limite de venda em %.0f nao cabe acima do bid %.0f", preco, bid);
         return;
      }

      double stop = NormalizePrice(isLong ? preco - risk   : preco + risk);
      double tp   = NormalizePrice(isLong ? preco + reward : preco - reward);

      ok = isLong
         ? trade.BuyLimit (lots, preco, _Symbol, stop, tp, ORDER_TIME_GTC, 0, "Delta div limite")
         : trade.SellLimit(lots, preco, _Symbol, stop, tp, ORDER_TIME_GTC, 0, "Delta div limite");

      if(ok && InpLog)
         PrintFormat("Limite %s em %.0f | offset %d pontos | validade %d barras | stop %d | alvo %d",
                     isLong ? "COMPRA" : "VENDA", preco,
                     InpLimitOffset, InpOrderValidBars, InpStopPoints, InpTakePoints);
   }
   else
   {
      double entry = isLong ? ask : bid;
      double stop  = NormalizePrice(isLong ? entry - risk   : entry + risk);
      double tp    = NormalizePrice(isLong ? entry + reward : entry - reward);

      ok = isLong ? trade.Buy (lots, _Symbol, 0.0, stop, tp, "Delta div")
                  : trade.Sell(lots, _Symbol, 0.0, stop, tp, "Delta div");
   }

   if(ok)
      horaUltimaEntrada = TimeCurrent();
   else
      PrintFormat("Falha na ordem: %d - %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
