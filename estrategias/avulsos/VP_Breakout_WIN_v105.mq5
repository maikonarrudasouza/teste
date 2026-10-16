//+------------------------------------------------------------------+
//|                                        VP_Breakout_WIN.mq5       |
//|  Rompimento da Value Area sobre perfil de volume movel de M1.     |
//|                                                                   |
//|  A camada de calculo do perfil (CalcProfile) e independente da     |
//|  logica de entrada. Voce pode trocar a estrategia sem tocar nela.  |
//|                                                                   |
//|  v1.03 - entrada por ordem LIMITE no nivel rompido.               |
//|          A execucao da limite JA E o reteste: se o preco voltou    |
//|          ao nivel, a ordem foi preenchida.                         |
//|                                                                   |
//|  v1.05 - offset da limite padrao = 200 pontos.                     |
//|          MODO CAUTELOSO: quando o preco vai e volta (N reversoes   |
//|          de pelo menos X pontos na janela), o rompimento precisa   |
//|          passar da VAH/VAL com folga maior. Nao bloqueia: so        |
//|          apertar a entrada. Fica ligado no minimo InpChopHoldMin.  |
//+------------------------------------------------------------------+
#property copyright "Maikon"
#property version   "1.05"
#property strict

#include <Trade\Trade.mqh>

//--- Perfil de volume
input int    InpProfileBars     = 120;    // Barras M1 cobertas pelo perfil
input int    InpBins            = 50;     // Numero de faixas de preco do perfil
input double InpValueAreaPct    = 70.0;   // % do volume dentro da Value Area
input bool   InpUseTickVolume   = false;  // Usar tick volume (false = volume real da B3)

//--- Modo de entrada
enum EEntryMode
{
   ENTRY_LIMIT         = 0,  // Ordem limite no nivel rompido
   ENTRY_MARKET_RETEST = 1   // A mercado, apos barra de reteste confirmar
};

input EEntryMode InpEntryMode   = ENTRY_LIMIT;  // Modo de entrada

//--- Entrada por LIMITE
input int    InpLimitOffset     = 200;    // Distancia da limite ate o nivel rompido (pontos)
input int    InpOrderValidBars  = 1;      // Barras de validade da ordem limite
input int    InpStopPoints      = 120;    // Stop em pontos
input int    InpTakePoints      = 120;    // Alvo em pontos

//--- Entrada a MERCADO (modo alternativo, usa ATR)
input int    InpRetestBars      = 10;     // Barras de validade do setup apos o rompimento
input double InpStopBufferATR   = 0.30;   // Folga do stop alem da barra de reteste
input double InpRR              = 1.0;    // Relacao risco/retorno do alvo
input int    InpMaxStopPoints   = 150;    // Teto do stop em pontos (0 = sem teto)
input int    InpMaxTakePoints   = 150;    // Teto do alvo em pontos (0 = sem teto)

//--- Filtros comuns
input double InpBreakBufferATR  = 0.10;   // Folga do rompimento, em fracao do ATR
input double InpMinVAWidthATR   = 1.00;   // Largura minima da VA em ATR

//--- Trailing por DEGRAU (roda a cada tick, fora do gatilho de nova barra).
//--- Desligue InpUsarTrailing para operar so com o stop e o alvo fixos.
input bool   InpUsarTrailing    = true;   // false = sai apenas no stop ou no take
input int    InpBreakevenEm     = 50;     // Lucro que dispara a protecao da entrada
input int    InpTravaInicial    = 25;     // Pontos acima da entrada onde o stop pousa
input int    InpDegrauPts       = 5;      // A cada N pontos que o preco andar, o stop anda N

//--- MODO CAUTELOSO (mercado indo e voltando)
//--- Reversao = o preco vira de direcao andando ao menos InpChopPts contra
//--- o ultimo topo/fundo. Nao bloqueia: so aumenta a folga do rompimento.
input bool   InpUsarFiltroChop  = true;   // Apertar a entrada quando o mercado vai e volta
input int    InpChopJanelaMin   = 30;     // Janela de leitura (minutos)
input int    InpChopPts         = 200;    // Recuo minimo para contar uma reversao (pontos)
input int    InpChopReversoes   = 2;      // Reversoes na janela que ligam o modo cauteloso
input int    InpChopHoldMin     = 20;     // Fica cauteloso por no minimo (minutos)
input double InpChopFatorBuffer = 2.0;    // Multiplica a folga do rompimento no modo cauteloso

//--- Volume
input double InpLots            = 1.0;    // Contratos por operacao

//--- Filtro de horario (desligado por padrao)
input bool   InpUseTimeFilter   = false;  // Ativar filtro de horario
input int    InpStartHour       = 9;      // Hora inicial (servidor)
input int    InpEndHour         = 21;     // Hora final (servidor)

//--- Operacional
input int    InpMagic           = 470784;
input int    InpSlippage        = 20;
input bool   InpLogDiagnostico  = true;   // Registra detalhes de cada ordem

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
input int    InpRajNiveis     = 10;     // Niveis (ticks) que o preco andou contra
input int    InpRajMediaN     = 30;     // Barras M1 para medir o volume normal

//--- estado da regra de cancelamento por agressao
double   g_rajFator  = 0.0;   // ultima leitura, em x o volume normal
datetime g_rajUltSeg = 0;     // leitura no maximo 1x por segundo

//+------------------------------------------------------------------+
CTrade        trade;
int           hATR = INVALID_HANDLE;
datetime      lastBarTime = 0;

//--- Estado do modo cauteloso
datetime chopUltBarra = 0;     // ultima barra M1 ja lida
datetime chopAte      = 0;     // cauteloso ate este instante
bool     chopAtivo    = false;
int      chopRev      = 0;     // reversoes contadas na ultima leitura

//--- Estado do setup pendente (usado so no modo a mercado)
enum ESetupDir { SETUP_NONE = 0, SETUP_LONG = 1, SETUP_SHORT = -1 };

struct SetupState
{
   ESetupDir dir;
   double    level;        // borda rompida (VAH para long, VAL para short)
   int       barsLeft;     // validade restante
};
SetupState setup;

//--- Resultado do perfil
struct ProfileResult
{
   bool   valid;
   double poc;
   double vah;
   double val;
};

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hATR = iATR(_Symbol, PERIOD_M1, 14);
   if(hATR == INVALID_HANDLE)
   {
      Print("Falha ao criar handle do ATR");
      return INIT_FAILED;
   }

   if(InpProfileBars < 30 || InpBins < 5)
   {
      Print("Parametros de perfil invalidos");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpEntryMode == ENTRY_LIMIT)
   {
      if(InpOrderValidBars < 1)
      {
         Print("Validade da ordem limite deve ser de ao menos 1 barra");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpStopPoints <= 0 || InpTakePoints <= 0 || InpLimitOffset <= 0)
      {
         Print("Offset, stop e alvo devem ser maiores que zero");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpTakePoints < InpStopPoints)
         PrintFormat("Atencao: risco/retorno negativo (stop %d x alvo %d). "
                     "Exige acerto acima de %.1f%% so para empatar.",
                     InpStopPoints, InpTakePoints,
                     100.0 * InpStopPoints / (InpStopPoints + InpTakePoints));

      PrintFormat("Modo LIMITE | offset %d pontos | validade %d barra(s) | stop %d | alvo %d",
                  InpLimitOffset, InpOrderValidBars, InpStopPoints, InpTakePoints);
   }
   else
      PrintFormat("Modo MERCADO/RETESTE | teto stop %d | teto alvo %d",
                  InpMaxStopPoints, InpMaxTakePoints);

   //--- trailing
   if(InpUsarTrailing)
   {
      double tickSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSz <= 0.0) tickSz = _Point;
      double tickPts = tickSz / _Point;
      double folga   = InpBreakevenEm - InpTravaInicial;

      PrintFormat("Trailing LIGADO: em +%d o stop vai para a entrada +%d pontos",
                  InpBreakevenEm, InpTravaInicial);
      PrintFormat("Depois disso, a cada %d pts que o preco andar o stop anda %d "
                  "(folga constante de %.0f pontos)",
                  InpDegrauPts, InpDegrauPts, folga);

      //--- com o trailing, o alvo fixo deixa de ser a saida tipica.
      //--- A maioria dos ganhadores vai sair perto da trava, nao no alvo.
      if(folga > 0.0 && InpStopPoints > 0)
      {
         double ganhoTipico = InpTravaInicial;
         PrintFormat("Atencao: com folga de %.0f, o ganho tipico cai para perto de "
                     "%.0f pontos enquanto a perda continua %d. Isso exige acerto "
                     "de ~%.1f%% para empatar (sem trailing, com alvo %d, seriam %.1f%%).",
                     folga, ganhoTipico, InpStopPoints,
                     100.0 * InpStopPoints / (InpStopPoints + ganhoTipico),
                     InpTakePoints,
                     100.0 * InpStopPoints / (InpStopPoints + InpTakePoints));
      }

      if(folga <= 0.0)
         Print("ERRO: a trava pousa em cima ou acima do preco - reveja "
               "InpBreakevenEm e InpTravaInicial");

      long nivelMin = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      if(nivelMin > 0 && folga <= (double)nivelMin)
         PrintFormat("ERRO: a folga de %.0f pontos nao supera o nivel minimo da "
                     "corretora (%d) - o trailing NUNCA sera aplicado",
                     folga, (int)nivelMin);

      if(MathAbs(InpDegrauPts / tickPts - MathRound(InpDegrauPts / tickPts)) > 0.001)
         PrintFormat("Atencao: o degrau de %d pontos nao e multiplo do tick de %.0f",
                     InpDegrauPts, tickPts);
      if(MathAbs(InpTravaInicial / tickPts - MathRound(InpTravaInicial / tickPts)) > 0.001)
         PrintFormat("Atencao: a trava de %d pontos nao e multipla do tick de %.0f",
                     InpTravaInicial, tickPts);
   }
   else
      Print("Trailing DESLIGADO: saida apenas no stop ou no alvo fixos");

   //--- modo cauteloso
   if(InpUsarFiltroChop)
   {
      if(InpChopJanelaMin < 5 || InpChopPts <= 0 || InpChopReversoes < 1 ||
         InpChopHoldMin < 0 || InpChopFatorBuffer < 1.0)
      {
         Print("Parametros do modo cauteloso invalidos (janela>=5, pontos>0, "
               "reversoes>=1, hold>=0, fator>=1.0)");
         return INIT_PARAMETERS_INCORRECT;
      }
      PrintFormat("Modo cauteloso: %d reversoes de %d+ pts em %d min liga a cautela "
                  "(folga do rompimento x%.1f, fica ligado ao menos %d min)",
                  InpChopReversoes, InpChopPts, InpChopJanelaMin,
                  InpChopFatorBuffer, InpChopHoldMin);
   }
   else
      Print("Modo cauteloso DESLIGADO");

   ResetSetup();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
}

void ResetSetup()
{
   setup.dir      = SETUP_NONE;
   setup.level    = 0.0;
   setup.barsLeft = 0;
}

//+------------------------------------------------------------------+
//| CAMADA 1 - CALCULO DO PERFIL DE VOLUME                           |
//| Distribui o volume de cada vela uniformemente entre low e high.  |
//+------------------------------------------------------------------+
ProfileResult CalcProfile(int bars, int bins, double vaPct)
{
   ProfileResult res;
   res.valid = false;
   res.poc = res.vah = res.val = 0.0;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   // shift 1: ignora a barra em formacao
   int copied = CopyRates(_Symbol, PERIOD_M1, 1, bars, rates);
   if(copied < bars / 2) return res;   // historico insuficiente

   double lo = rates[0].low, hi = rates[0].high;
   for(int i = 1; i < copied; i++)
   {
      if(rates[i].low  < lo) lo = rates[i].low;
      if(rates[i].high > hi) hi = rates[i].high;
   }
   double range = hi - lo;
   if(range <= 0.0) return res;

   double binSize = range / bins;
   double vol[];
   ArrayResize(vol, bins);
   ArrayInitialize(vol, 0.0);

   for(int i = 0; i < copied; i++)
   {
      double v = InpUseTickVolume ? (double)rates[i].tick_volume
                                  : (double)rates[i].real_volume;
      if(v <= 0.0) v = (double)rates[i].tick_volume;   // fallback
      if(v <= 0.0) continue;

      double barLow  = rates[i].low;
      double barHigh = rates[i].high;
      double barRange = barHigh - barLow;

      if(barRange <= 0.0)
      {
         int idx = (int)MathFloor((barLow - lo) / binSize);
         idx = (int)MathMin(MathMax(idx, 0), bins - 1);
         vol[idx] += v;
         continue;
      }

      // reparte o volume proporcionalmente a sobreposicao com cada faixa
      int first = (int)MathFloor((barLow  - lo) / binSize);
      int last  = (int)MathFloor((barHigh - lo) / binSize);
      first = (int)MathMin(MathMax(first, 0), bins - 1);
      last  = (int)MathMin(MathMax(last,  0), bins - 1);

      for(int b = first; b <= last; b++)
      {
         double binLow  = lo + b * binSize;
         double binHigh = binLow + binSize;
         double ovLow   = MathMax(binLow,  barLow);
         double ovHigh  = MathMin(binHigh, barHigh);
         double ov      = ovHigh - ovLow;
         if(ov > 0.0) vol[b] += v * (ov / barRange);
      }
   }

   // POC
   int pocIdx = 0;
   double totalVol = 0.0;
   for(int b = 0; b < bins; b++)
   {
      totalVol += vol[b];
      if(vol[b] > vol[pocIdx]) pocIdx = b;
   }
   if(totalVol <= 0.0) return res;

   // Value Area: expande a partir do POC pelo vizinho de maior volume
   double target = totalVol * (vaPct / 100.0);
   double acc = vol[pocIdx];
   int up = pocIdx, dn = pocIdx;

   while(acc < target && (up < bins - 1 || dn > 0))
   {
      double volUp = (up < bins - 1) ? vol[up + 1] : -1.0;
      double volDn = (dn > 0)        ? vol[dn - 1] : -1.0;

      if(volUp >= volDn && volUp >= 0.0)      { up++; acc += vol[up]; }
      else if(volDn >= 0.0)                   { dn--; acc += vol[dn]; }
      else break;
   }

   res.poc   = lo + (pocIdx + 0.5) * binSize;
   res.vah   = lo + (up + 1) * binSize;
   res.val   = lo + dn * binSize;
   res.valid = true;
   return res;
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

double GetATR()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hATR, 0, 1, 1, buf) < 1) return 0.0;
   return buf[0];
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
         if(InpLogDiagnostico)
            PrintFormat("Limite cancelada: %d barra(s) sem execucao", InpOrderValidBars);
      }
   }
}

//--- cancela qualquer ordem pendente deste EA
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

//--- arredonda para o multiplo valido do tick (WIN negocia de 5 em 5 pontos)
double NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) return NormalizeDouble(price, _Digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

//--- volume fixo, apenas ajustado aos limites do simbolo
double CalcLots()
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0.0) lotStep = 1.0;
   int digitsLot = (lotStep >= 1.0) ? 0 : 2;

   double lots = MathMin(MathMax(InpLots, minLot), maxLot);
   return NormalizeDouble(lots, digitsLot);
}

//+------------------------------------------------------------------+
//| Cotacao atual, com o ultimo negocio como alternativa.            |
//| Na B3 o book pode vir zerado enquanto os negocios continuam.     |
//| Usado so pelo trailing - a logica de entrada segue como estava.  |
//+------------------------------------------------------------------+
bool GetQuotes(double &ask, double &bid)
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return false;

   ask = t.ask;
   bid = t.bid;

   if((ask <= 0.0 || bid <= 0.0) && t.last > 0.0)
   {
      ask = t.last;
      bid = t.last;
   }
   return (ask > 0.0 && bid > 0.0 && ask >= bid);
}

//+------------------------------------------------------------------+
//| TRAILING POR DEGRAU                                              |
//|                                                                   |
//| O stop sobe em degraus do mesmo tamanho do avanco do preco: a     |
//| cada InpDegrauPts que o preco anda, o stop anda InpDegrauPts.     |
//| A folga entre preco e stop fica constante em                      |
//| InpBreakevenEm - InpTravaInicial.                                 |
//|                                                                   |
//| Comprado em 140.000, gatilho +50, trava +25, degrau 5:            |
//|                                                                   |
//|   lucro   stop            travado   folga                         |
//|   ----------------------------------------------                  |
//|   +45     139.880          -120      --   (nada ainda)            |
//|   +50     140.025           +25      25                           |
//|   +100    140.075           +75      25                           |
//|   +200    140.175          +175      25                           |
//|                                                                   |
//| O calculo e absoluto, deduzido da entrada e do numero de degraus  |
//| completos - nao incremental. Se o terminal cair ou o EA for       |
//| recarregado no meio do trade, na volta o stop pula direto para o  |
//| degrau correto em vez de ficar defasado.                          |
//|                                                                   |
//| Roda ANTES do IsNewBar: gerenciar posicao e tarefa de cada tick.  |
//| Dentro do gatilho de barra, o stop ficaria ate 60s atrasado.      |
//+------------------------------------------------------------------+
void GerenciarTrailing()
{
   if(!InpUsarTrailing) return;
   if(InpDegrauPts <= 0) return;

   double ask = 0.0, bid = 0.0;
   if(!GetQuotes(ask, bid)) return;

   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool   isLong    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double entrada   = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopAtual = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);

      //--- preco pelo qual a posicao fecharia agora
      double precoSaida = isLong ? bid : ask;
      double lucroPts   = (isLong ? (precoSaida - entrada)
                                  : (entrada - precoSaida)) / _Point;

      //--- ainda nao chegou na protecao da entrada
      if(lucroPts < InpBreakevenEm) continue;

      //--- quantos degraus COMPLETOS o preco andou alem do gatilho
      int degraus = (int)MathFloor((lucroPts - InpBreakevenEm) / InpDegrauPts);

      double avanco = (InpTravaInicial + degraus * InpDegrauPts) * _Point;
      double novo   = NormalizePrice(isLong ? entrada + avanco : entrada - avanco);

      //--- o stop nunca afrouxa. Como os degraus sao discretos, so ha
      //--- modificacao quando um degrau novo e alcancado - sem isso
      //--- seria um PositionModify por tick e o servidor recusaria.
      if(stopAtual > 0.0)
      {
         if(isLong  && novo <= stopAtual) continue;
         if(!isLong && novo >= stopAtual) continue;
      }

      //--- distancia minima exigida pela corretora
      if(isLong  && novo >= bid - stopLevel) continue;
      if(!isLong && novo <= ask + stopLevel) continue;

      if(trade.PositionModify(ticket, novo, tp))
      {
         if(InpLogDiagnostico)
            PrintFormat("Trailing %s: degrau %d | stop %.0f -> %.0f | lucro %.0f pts | travado %+.0f",
                        isLong ? "COMPRA" : "VENDA", degraus,
                        stopAtual, novo, lucroPts,
                        (isLong ? novo - entrada : entrada - novo) / _Point);
      }
      else
         PrintFormat("Trailing falhou: %d - %s", trade.ResultRetcode(),
                     trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| MODO CAUTELOSO - MERCADO INDO E VOLTANDO                         |
//|                                                                   |
//| Conta reversoes de um zigzag de InpChopPts pontos sobre as barras |
//| M1 fechadas da janela. A primeira pernada so define a direcao; a  |
//| partir dela, cada vez que o preco vira ao menos InpChopPts contra |
//| o ultimo extremo, conta uma reversao.                              |
//|                                                                   |
//| Cada barra vira dois pontos de preco, na ordem provavel: barra de |
//| alta passa pela minima antes da maxima, barra de baixa o inverso. |
//| Sem isso, uma barra grande de alta contaria como reversao so por  |
//| ter minima e maxima distantes.                                     |
//+------------------------------------------------------------------+
int ContarReversoes(const MqlRates &r[], int n, double limite)
{
   if(n < 2 || limite <= 0.0) return 0;

   int    dir = 0, rev = 0, iHi = 0, iLo = 0;
   double extremo = 0.0, hi = 0.0, lo = 0.0;
   bool   inicio = true;

   for(int i = 0; i < n; i++)
   {
      bool   alta = (r[i].close >= r[i].open);
      double p0   = alta ? r[i].low  : r[i].high;
      double p1   = alta ? r[i].high : r[i].low;

      for(int k = 0; k < 2; k++)
      {
         double p   = (k == 0) ? p0 : p1;
         int    idx = i * 2 + k;

         if(inicio)
         {
            hi = lo = p;
            iHi = iLo = idx;
            inicio = false;
            continue;
         }

         if(dir == 0)
         {
            //--- ainda sem direcao: espera a primeira pernada de ao menos limite
            if(p > hi) { hi = p; iHi = idx; }
            if(p < lo) { lo = p; iLo = idx; }
            if(hi - lo >= limite)
            {
               if(iHi > iLo) { dir =  1; extremo = hi; }
               else          { dir = -1; extremo = lo; }
            }
         }
         else if(dir == 1)
         {
            if(p > extremo)                       extremo = p;
            else if(extremo - p >= limite)      { rev++; dir = -1; extremo = p; }
         }
         else
         {
            if(p < extremo)                       extremo = p;
            else if(p - extremo >= limite)      { rev++; dir =  1; extremo = p; }
         }
      }
   }
   return rev;
}

//--- relê o mercado uma vez por barra M1 fechada
void AtualizarChop()
{
   if(!InpUsarFiltroChop) return;

   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t <= 0 || t == chopUltBarra) return;
   chopUltBarra = t;

   MqlRates r[];
   ArraySetAsSeries(r, false);                      // do mais antigo para o mais novo
   int n = CopyRates(_Symbol, PERIOD_M1, 1, InpChopJanelaMin, r);
   if(n < InpChopJanelaMin / 2) return;             // historico insuficiente

   chopRev = ContarReversoes(r, n, InpChopPts * _Point);

   if(chopRev >= InpChopReversoes)
   {
      if(!chopAtivo && InpLogDiagnostico)
         PrintFormat("MODO CAUTELOSO ligado: %d reversoes de %d+ pts em %d min "
                     "(rompimento exige folga x%.1f)",
                     chopRev, InpChopPts, InpChopJanelaMin, InpChopFatorBuffer);
      chopAtivo = true;
      chopAte   = TimeCurrent() + InpChopHoldMin * 60;
   }
}

//--- true enquanto o mercado esta indo e voltando (e por InpChopHoldMin depois)
bool ModoCauteloso()
{
   if(!InpUsarFiltroChop) return false;

   AtualizarChop();

   if(chopAtivo && TimeCurrent() >= chopAte)
   {
      chopAtivo = false;
      if(InpLogDiagnostico)
         Print("Modo cauteloso desligado: mercado voltou a andar");
   }
   return chopAtivo;
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
//| CAMADA 2 - LOGICA DE ENTRADA                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- gerenciar posicao aberta e tarefa de TODO tick, nao de cada barra
   GerenciarTrailing();
   CancelarPorRajada();

   if(!IsNewBar()) return;

   //--- posicao aberta: limpa pendencias e espera
   if(HasOpenPosition())
   {
      ResetSetup();
      if(InpEntryMode == ENTRY_LIMIT) CancelAllOrders();
      return;
   }

   //--- modo limite: gerencia validade antes de procurar novo sinal
   if(InpEntryMode == ENTRY_LIMIT)
   {
      CancelExpiredOrders();
      if(HasPendingOrder()) return;   // ja tem ordem na fila
   }

   double atr = GetATR();
   if(atr <= 0.0) return;

   ProfileResult vp = CalcProfile(InpProfileBars, InpBins, InpValueAreaPct);
   if(!vp.valid) return;

   // descarta perfil estreito demais: sem estrutura, rompimento nao significa nada
   if((vp.vah - vp.val) < InpMinVAWidthATR * atr) { ResetSetup(); return; }

   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double low1   = iLow(_Symbol,   PERIOD_M1, 1);
   double high1  = iHigh(_Symbol,  PERIOD_M1, 1);
   //--- mercado indo e voltando: o rompimento precisa passar com mais folga
   bool   caut   = ModoCauteloso();
   double buffer = InpBreakBufferATR * atr * (caut ? InpChopFatorBuffer : 1.0);

   //--- 1) Setup pendente: procura o reteste (so no modo a mercado)
   if(InpEntryMode == ENTRY_MARKET_RETEST && setup.dir != SETUP_NONE)
   {
      setup.barsLeft--;

      if(setup.dir == SETUP_LONG)
      {
         // tocou a borda de volta e fechou acima dela
         if(low1 <= setup.level && close1 > setup.level)
         {
            double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double stop  = low1 - InpStopBufferATR * atr;
            if(entry > 0.0 && stop < entry) OpenTradeMarket(true, entry, stop);
            else if(entry <= 0.0) Print("Cotacao indisponivel (ask=0) - entrada ignorada");
            ResetSetup();
            return;
         }
         // rompimento invalidado: voltou para dentro da VA
         if(close1 < setup.level - buffer) { ResetSetup(); return; }
      }
      else // SETUP_SHORT
      {
         if(high1 >= setup.level && close1 < setup.level)
         {
            double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double stop  = high1 + InpStopBufferATR * atr;
            if(entry > 0.0 && stop > entry) OpenTradeMarket(false, entry, stop);
            else if(entry <= 0.0) Print("Cotacao indisponivel (bid=0) - entrada ignorada");
            ResetSetup();
            return;
         }
         if(close1 > setup.level + buffer) { ResetSetup(); return; }
      }

      if(setup.barsLeft <= 0) ResetSetup();
      return;
   }

   //--- 2) Procura o rompimento
   if(!TimeAllowed()) return;

   bool rompeuAlta  = (close1 > vp.vah + buffer);
   bool rompeuBaixa = (close1 < vp.val - buffer);

   if(!rompeuAlta && !rompeuBaixa) return;

   if(InpEntryMode == ENTRY_LIMIT)
   {
      // a execucao da limite JA E o reteste: nao ha estado a guardar
      PlaceLimitOrder(rompeuAlta, rompeuAlta ? vp.vah : vp.val);
      return;
   }

   if(rompeuAlta)
   {
      setup.dir      = SETUP_LONG;
      setup.level    = vp.vah;
      setup.barsLeft = InpRetestBars;
   }
   else
   {
      setup.dir      = SETUP_SHORT;
      setup.level    = vp.val;
      setup.barsLeft = InpRetestBars;
   }
}

//+------------------------------------------------------------------+
//| Ordem LIMITE no nivel rompido                                    |
//| Compra: limite abaixo do preco atual. Venda: acima.              |
//+------------------------------------------------------------------+
void PlaceLimitOrder(bool isLong, double level)
{
   double offset = InpLimitOffset * _Point;
   double risk   = InpStopPoints  * _Point;
   double reward = InpTakePoints  * _Point;

   // rompeu por cima -> espera o preco recuar ate abaixo do nivel
   // rompeu por baixo -> espera o preco subir ate acima do nivel
   double preco = isLong ? level - offset : level + offset;
   preco = NormalizePrice(preco);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- cotacao invalida: sem isso a ordem sai com preco calculado a partir do zero
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
   {
      PrintFormat("Cotacao indisponivel (ask=%.0f bid=%.0f) - ordem ignorada", ask, bid);
      return;
   }

   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   //--- a limite precisa estar do lado certo do preco atual
   if(isLong && preco >= ask - stopLevel)
   {
      if(InpLogDiagnostico)
         PrintFormat("Limite de compra em %.0f nao cabe abaixo do ask %.0f - ignorada",
                     preco, ask);
      return;
   }
   if(!isLong && preco <= bid + stopLevel)
   {
      if(InpLogDiagnostico)
         PrintFormat("Limite de venda em %.0f nao cabe acima do bid %.0f - ignorada",
                     preco, bid);
      return;
   }

   double stop = NormalizePrice(isLong ? preco - risk   : preco + risk);
   double tp   = NormalizePrice(isLong ? preco + reward : preco - reward);

   double lots = CalcLots();

   bool ok = isLong
      ? trade.BuyLimit (lots, preco, _Symbol, stop, tp, ORDER_TIME_GTC, 0, "VP limite")
      : trade.SellLimit(lots, preco, _Symbol, stop, tp, ORDER_TIME_GTC, 0, "VP limite");

   if(ok)
   {
      if(InpLogDiagnostico)
         PrintFormat("Limite %s em %.0f | nivel rompido %.0f | offset %d | validade %d barra(s)",
                     isLong ? "COMPRA" : "VENDA", preco, level,
                     InpLimitOffset, InpOrderValidBars);
   }
   else
      PrintFormat("Falha na ordem limite: %d - %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Entrada a mercado (modo alternativo, stop derivado do ATR)       |
//+------------------------------------------------------------------+
void OpenTradeMarket(bool isLong, double entry, double stop)
{
   double risk = MathAbs(entry - stop);

   //--- TETO DO STOP: se o ATR pedir mais que o limite, limita ao teto
   if(InpMaxStopPoints > 0)
   {
      double maxRisk = InpMaxStopPoints * _Point;
      if(risk > maxRisk)
      {
         PrintFormat("Stop de %.0f pontos limitado ao teto de %d", risk / _Point, InpMaxStopPoints);
         risk = maxRisk;
         stop = isLong ? entry - maxRisk : entry + maxRisk;
      }
   }

   // stop apertado demais vira ruido de spread
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(risk < minStop || risk <= 0.0)
   {
      PrintFormat("Stop de %.0f pontos abaixo do minimo da corretora (%.0f) - operacao ignorada",
                  risk / _Point, minStop / _Point);
      return;
   }

   //--- ALVO: proporcional ao risco, tambem limitado ao teto
   double reward = risk * InpRR;
   if(InpMaxTakePoints > 0)
      reward = MathMin(reward, InpMaxTakePoints * _Point);

   double tp = isLong ? entry + reward : entry - reward;

   stop = NormalizePrice(stop);
   tp   = NormalizePrice(tp);

   double lots = CalcLots();

   bool ok = isLong ? trade.Buy(lots, _Symbol, 0.0, stop, tp, "VP mercado")
                    : trade.Sell(lots, _Symbol, 0.0, stop, tp, "VP mercado");

   if(!ok)
      PrintFormat("Falha na ordem: %d - %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+