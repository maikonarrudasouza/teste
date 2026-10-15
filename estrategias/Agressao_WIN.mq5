//+------------------------------------------------------------------+
//|                                                Agressao_WIN.mq5   |
//|  Robô de agressão para WIN, baseado no "Guia do Tape Reading"     |
//|  (Wilson Neto, cap. 9 Agressões):                                 |
//|   "A agressão se dá quando uma única oferta, de compra ou venda,  |
//|    executa a mercado a ponta contrária de vários participantes,   |
//|    movendo o preço."                                              |
//|  Como o robô lê isso no Times & Trades (ticks de negócio):        |
//|   1. Numa janela curta (10 s), compras a mercado sobem o preço    |
//|      por vários níveis (3 = 15 pts), com volume bem acima do      |
//|      normal e quase todo do lado comprador.                       |
//|   2. O preço segura o novo patamar até o fechamento da barra.     |
//|   3. Entrada a favor no recuo: compra limitada X pontos abaixo do |
//|      fechamento da barra, válida por poucas barras.               |
//|   Na venda, tudo espelhado.                                       |
//|  Gestão: stop e alvo fixos, trailing stop, 1 posição por vez,     |
//|  sem aumento de mão, zera no fim do dia.                          |
//+------------------------------------------------------------------+
#property copyright   "maikon arruda"
#property version     "1.01"
#property description "Agressão no Times & Trades (Guia do Tape Reading) para WIN (B3)"

#include <Trade/Trade.mqh>

input group "Geral"
input ulong           InpMagic            = 212010;     // Número mágico
input double          InpLotes            = 1;          // Contratos por entrada (sem aumento de mão)
input ENUM_TIMEFRAMES InpTF               = PERIOD_M1;  // Tempo gráfico

input group "Horário (hora do servidor)"
input string          InpInicio           = "09:15";    // Início das entradas
input string          InpFimEntradas      = "17:15";    // Fim das entradas
input string          InpZerar            = "17:50";    // Hora de zerar
input bool            InpZerarFimDia      = true;       // Zerar todo dia no horário InpZerar

input group "Agressão (Times & Trades)"
input int             InpJanelaSeg        = 10;         // Janela da agressão (segundos)
input int             InpNiveisMin        = 3;          // Níveis de preço varridos (3 x 5 = 15 pts)
input double          InpFatorVolume      = 3.0;        // Volume na janela >= fator x volume normal da janela
input double          InpDominioPct       = 70;         // % do volume agredido do lado da agressão
input int             InpMediaN           = 30;         // Barras para medir o volume normal
input bool            InpExigirSustentar  = true;       // Barra precisa fechar acima (compra) do início da agressão

input group "Entrada"
input int             InpOffsetLimite     = 110;        // Limitada: pontos melhor que o fechamento da barra
input int             InpValidadeOrdem    = 2;          // Barras que a ordem limitada fica viva

input group "Stop e alvo"
input int             InpStopFixo         = 125;        // Stop (pontos)
input int             InpAlvoFixo         = 500;        // Gain (pontos)

input group "Trailing stop"
input bool            InpTrailing         = true;       // Ligar trailing stop
input int             InpTrailAtivar      = 50;         // Ativa depois de X pontos a favor
input int             InpTrailDist        = 5;          // Distância do stop para o preço (5 = 1 tick do WIN)

input group "Limites do dia"
input int             InpMaxOperacoesDia  = 6;          // Máximo de entradas por dia
input double          InpPerdaMaxDia      = 300;        // Perda máxima do dia em R$ (0 = sem limite)
input int             InpPerdasSeguidas   = 3;          // Para no dia após N perdas seguidas (0 = não)

//--- estado
CTrade   trade;
datetime g_ultimaBarra = 0;
ulong    g_ordem       = 0;
int      g_ordemBarras = 0;
bool     g_avisoFlags  = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Utilidades                                                        |
//+------------------------------------------------------------------+
double Tick()
  {
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return (t > 0) ? t : _Point;
  }

double Pts(double p) { return p * _Point; }

double Arred(double preco)
  {
   double t = Tick();
   return NormalizeDouble(MathRound(preco / t) * t, _Digits);
  }

int Minutos(const string hhmm)
  {
   string p[];
   if(StringSplit(hhmm, ':', p) != 2)
      return 0;
   return (int)StringToInteger(p[0]) * 60 + (int)StringToInteger(p[1]);
  }

int MinutosAgora()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour * 60 + dt.min;
  }

datetime InicioDoDia(datetime t) { return t - (t % 86400); }

double Vol(const MqlRates &r) { return (r.real_volume > 0) ? (double)r.real_volume : (double)r.tick_volume; }

double VolTick(const MqlTick &t) { return (t.volume_real > 0) ? t.volume_real : (double)t.volume; }

// ajusta o lote ao mínimo, máximo e passo da corretora
double Lote(double l)
  {
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0)
      st = mn;
   l = MathFloor(l / st + 1e-9) * st;
   return NormalizeDouble(MathMax(mn, MathMin(mx, l)), 2);
  }

//+------------------------------------------------------------------+
//| Posições e ordens do robô                                         |
//+------------------------------------------------------------------+
int ListarPosicoes(ulong &t[])
  {
   ArrayResize(t, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;
      int n = ArraySize(t);
      ArrayResize(t, n + 1);
      t[n] = tk;
     }
   return ArraySize(t);
  }

bool TemPosicao()
  {
   ulong t[];
   return ListarPosicoes(t) > 0;
  }

bool TemOrdem() { return g_ordem != 0 && OrderSelect(g_ordem); }

void CancelarOrdem()
  {
   if(TemOrdem())
      trade.OrderDelete(g_ordem);
   g_ordem = 0;
  }

void Zerar()
  {
   CancelarOrdem();
   ulong t[];
   int n = ListarPosicoes(t);
   for(int i = 0; i < n; i++)
      trade.PositionClose(t[i]);
  }

//+------------------------------------------------------------------+
//| Controle diário                                                   |
//+------------------------------------------------------------------+
void ResumoDia(int &entradas, double &resultado, int &perdasSeguidas)
  {
   entradas = 0;
   resultado = 0;
   perdasSeguidas = 0;
   if(!HistorySelect(InicioDoDia(TimeCurrent()), TimeCurrent() + 60))
      return;
   bool contando = true;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      long tipo = HistoryDealGetInteger(d, DEAL_ENTRY);
      double res = HistoryDealGetDouble(d, DEAL_PROFIT)
                   + HistoryDealGetDouble(d, DEAL_COMMISSION)
                   + HistoryDealGetDouble(d, DEAL_SWAP);
      resultado += res;
      if(tipo == DEAL_ENTRY_IN)
         entradas++;
      if(contando && (tipo == DEAL_ENTRY_OUT || tipo == DEAL_ENTRY_INOUT))
        {
         if(res < 0) perdasSeguidas++;
         else        contando = false;
        }
     }
  }

//+------------------------------------------------------------------+
//| Detecta agressão nos ticks da barra que acabou de fechar.         |
//| Retorna +1 (agressão compradora), -1 (vendedora) ou 0.            |
//| inicio = preço onde a agressão começou.                           |
//+------------------------------------------------------------------+
int Agressao(const MqlRates &barra, double volNormalBarra, double &inicio)
  {
   MqlTick tk[];
   ulong de  = (ulong)barra.time * 1000;
   ulong ate = (ulong)(barra.time + PeriodSeconds(InpTF)) * 1000 - 1;
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE, de, ate);
   if(n < 2)
      return 0;

   // lado agressor de cada negócio: flags da bolsa; sem elas, regra do tick
   bool temFlags = false;
   for(int i = 0; i < n && !temFlags; i++)
      if((tk[i].flags & (TICK_FLAG_BUY | TICK_FLAG_SELL)) != 0)
         temFlags = true;
   if(!temFlags && !g_avisoFlags)
     {
      Print("Aviso: os ticks não trazem o lado agressor; usando a regra do tick (subiu = compra, caiu = venda).");
      g_avisoFlags = true;
     }

   int lado[];
   ArrayResize(lado, n);
   int ultimo = 0;
   for(int i = 0; i < n; i++)
     {
      int l = 0;
      if(temFlags)
        {
         bool b = (tk[i].flags & TICK_FLAG_BUY)  != 0;
         bool s = (tk[i].flags & TICK_FLAG_SELL) != 0;
         l = (b && !s) ? +1 : (s && !b) ? -1 : 0;
        }
      else if(i > 0)
        {
         l = (tk[i].last > tk[i - 1].last) ? +1 : (tk[i].last < tk[i - 1].last) ? -1 : ultimo;
         ultimo = l;
        }
      lado[i] = l;
     }

   // volume normal numa janela do mesmo tamanho
   double volNormalJanela = volNormalBarra * InpJanelaSeg / (double)PeriodSeconds(InpTF);
   double niveis = InpNiveisMin * Tick();
   long   janelaMs = (long)InpJanelaSeg * 1000;

   int    melhorDir = 0;
   long   melhorFim = -1;
   double melhorIni = 0;

   // janela deslizante: para cada negócio inicial, soma até InpJanelaSeg depois
   int fim = 0;
   double vc = 0, vv = 0;
   for(int ini = 0; ini < n; ini++)
     {
      if(fim < ini)
        {
         fim = ini;
         vc = 0;
         vv = 0;
        }
      while(fim < n && tk[fim].time_msc - tk[ini].time_msc <= janelaMs)
        {
         double v = VolTick(tk[fim]);
         if(lado[fim] > 0) vc += v;
         if(lado[fim] < 0) vv += v;
         fim++;
        }
      double total = vc + vv;
      if(total > 0 && total >= InpFatorVolume * volNormalJanela)
        {
         double p0 = tk[ini].last;
         double maxP = p0, minP = p0;
         for(int k = ini; k < fim; k++)
           {
            maxP = MathMax(maxP, tk[k].last);
            minP = MathMin(minP, tk[k].last);
           }
         int dir = 0;
         if(vc >= InpDominioPct / 100.0 * total && maxP - p0 >= niveis - Tick() / 2)
            dir = +1;
         else if(vv >= InpDominioPct / 100.0 * total && p0 - minP >= niveis - Tick() / 2)
            dir = -1;
         // guarda a agressão mais recente da barra
         if(dir != 0 && (long)tk[fim - 1].time_msc > melhorFim)
           {
            melhorDir = dir;
            melhorFim = (long)tk[fim - 1].time_msc;
            melhorIni = p0;
           }
        }
      // tira o negócio inicial antes de avançar
      double v0 = VolTick(tk[ini]);
      if(lado[ini] > 0) vc -= v0;
      if(lado[ini] < 0) vv -= v0;
     }

   if(melhorDir == 0)
      return 0;
   // o preço segurou o novo patamar?
   if(InpExigirSustentar)
     {
      if(melhorDir > 0 && barra.close <= melhorIni)
         return 0;
      if(melhorDir < 0 && barra.close >= melhorIni)
         return 0;
     }
   inicio = melhorIni;
   return melhorDir;
  }

//+------------------------------------------------------------------+
//| Entrada: limitada X pontos melhor que o fechamento da barra       |
//+------------------------------------------------------------------+
void Entrar(int dir, double fechamento, double inicio)
  {
   double entrada = Arred(fechamento - dir * Pts(InpOffsetLimite));
   double stop    = Arred(entrada - dir * Pts(InpStopFixo));
   double alvo    = Arred(entrada + dir * Pts(InpAlvoFixo));
   double lote    = Lote(InpLotes);
   string cmt     = dir > 0 ? "Agressao compra" : "Agressao venda";

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok;
   if(dir > 0 && ask <= entrada)
      ok = trade.Buy(lote, _Symbol, 0, stop, alvo, cmt);
   else if(dir < 0 && bid >= entrada)
      ok = trade.Sell(lote, _Symbol, 0, stop, alvo, cmt);
   else
      ok = (dir > 0) ? trade.BuyLimit(lote, entrada, _Symbol, stop, alvo, ORDER_TIME_DAY, 0, cmt)
                     : trade.SellLimit(lote, entrada, _Symbol, stop, alvo, ORDER_TIME_DAY, 0, cmt);
   if(!ok || trade.ResultOrder() == 0)
     {
      PrintFormat("Falha ao enviar ordem (%u %s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }
   g_ordem       = trade.ResultOrder();
   g_ordemBarras = 0;
   PrintFormat("Agressão %s a partir de %.0f: %s limitada em %.0f | SL %.0f | gain %.0f",
               dir > 0 ? "compradora" : "vendedora", inicio,
               dir > 0 ? "compra" : "venda", entrada, stop, alvo);
  }

//+------------------------------------------------------------------+
//| Trailing: depois de X pontos a favor, o stop acompanha o preço a  |
//| uma distância fixa e só anda a favor                              |
//+------------------------------------------------------------------+
void GerirTrailing()
  {
   if(!InpTrailing)
      return;
   ulong t[];
   int n = ListarPosicoes(t);
   for(int i = 0; i < n; i++)
     {
      if(!PositionSelectByTicket(t[i]))
         continue;
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? +1 : -1;
      double abertura = PositionGetDouble(POSITION_PRICE_OPEN);
      double preco = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(dir * (preco - abertura) < Pts(InpTrailAtivar))
         continue;
      double novo = Arred(preco - dir * Pts(InpTrailDist));
      double sl = PositionGetDouble(POSITION_SL);
      if(sl == 0 || dir * (novo - sl) >= Tick())
         trade.PositionModify(t[i], novo, PositionGetDouble(POSITION_TP));
     }
  }

//+------------------------------------------------------------------+
void NovaBarra()
  {
   // validade da ordem limitada
   if(TemOrdem())
     {
      g_ordemBarras++;
      if(g_ordemBarras >= InpValidadeOrdem)
         CancelarOrdem();
      return;
     }
   g_ordem = 0;

   // uma posição por vez, sem aumento de mão
   if(TemPosicao())
      return;

   int agora = MinutosAgora();
   if(agora < Minutos(InpInicio) || agora >= Minutos(InpFimEntradas))
      return;

   int entradas, perdas;
   double resultado;
   ResumoDia(entradas, resultado, perdas);
   if(entradas >= InpMaxOperacoesDia)
      return;
   if(InpPerdaMaxDia > 0 && resultado <= -InpPerdaMaxDia)
      return;
   if(InpPerdasSeguidas > 0 && perdas >= InpPerdasSeguidas)
      return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTF, 1, InpMediaN + 1, r) < InpMediaN + 1)
      return;
   double soma = 0;
   for(int k = 1; k <= InpMediaN; k++)
      soma += Vol(r[k]);
   double volNormal = soma / InpMediaN;
   if(volNormal <= 0)
      return;

   double inicio = 0;
   int dir = Agressao(r[0], volNormal, inicio);
   if(dir != 0)
      Entrar(dir, r[0].close, inicio);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpZerarFimDia && MinutosAgora() >= Minutos(InpZerar))
     {
      Zerar();
      return;
     }

   GerirTrailing();

   datetime barra = iTime(_Symbol, InpTF, 0);
   if(barra != g_ultimaBarra)
     {
      g_ultimaBarra = barra;
      NovaBarra();
     }
  }
//+------------------------------------------------------------------+
