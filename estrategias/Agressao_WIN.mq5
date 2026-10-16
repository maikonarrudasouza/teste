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
#property version     "1.05"
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

enum ETipoMedia
  {
   MEDIA_COMUM      = 0,   // Média comum (EMA, SMA...)
   MEDIA_ADAPTATIVA = 1    // Média adaptativa (AMA/KAMA)
  };

input group "Filtro de tendência"
input bool            InpUsarFiltroTend   = false;      // Só operar a favor da média (desligado por padrão)
input ENUM_TIMEFRAMES InpTFTendencia      = PERIOD_M5;  // Tempo gráfico da média
input int             InpMAPeriodo        = 50;         // Período da média
input ENUM_MA_METHOD  InpMAMetodo         = MODE_EMA;   // Método da média
input int             InpMADistMin        = 25;         // Zona neutra em volta da média (pontos)
input ETipoMedia      InpMATipo           = MEDIA_COMUM;    // Tipo de média do filtro
input ENUM_APPLIED_PRICE InpMAPreco       = PRICE_WEIGHTED; // Preço aplicado da AMA (WEIGHTED = HLCC/4)
input int             InpAMAPeriodo       = 1;          // AMA: período
input int             InpAMARapida        = 6;          // AMA: EMA rápida
input int             InpAMALenta         = 30;         // AMA: EMA lenta

input group "Cancelar a limitada pela média"
input bool            InpCancelaMedia     = true;           // No fechamento da barra, cancela a limitada do lado contrário à média
input ENUM_TIMEFRAMES InpMCTF             = PERIOD_CURRENT; // Timeframe do candle e da média (CURRENT = o do robô)
input ETipoMedia      InpMCTipo           = MEDIA_ADAPTATIVA; // Tipo de média
input ENUM_APPLIED_PRICE InpMCPreco       = PRICE_WEIGHTED;   // Preço aplicado (WEIGHTED = HLCC/4)
input int             InpMCAMAPeriodo     = 1;           // AMA: período
input int             InpMCAMARapida      = 6;           // AMA: EMA rápida
input int             InpMCAMALenta       = 30;          // AMA: EMA lenta
input int             InpMCPeriodo        = 50;          // Média comum: período
input ENUM_MA_METHOD  InpMCMetodo         = MODE_EMA;    // Média comum: método
input int             InpMCFolga          = 0;           // Folga além da média (pontos)

input group "Proteção contra agressão"
input bool            InpProtecao         = false;      // Cancelar/zerar quando a agressão vem contra (desligada)
input int             InpProtJanelaSeg    = 10;         // Janela de leitura ao vivo (segundos)
input double          InpProtFator        = 3.0;        // Volume da janela >= fator x volume normal
input double          InpProtDominioPct   = 75;         // % do volume agredido de um lado
input int             InpProtNiveis       = 3;          // Níveis (ticks) que o preço andou contra
input bool            InpProtCancelar     = true;       // Cancelar a ordem limitada pendente
input bool            InpProtZerar        = true;       // Zerar a posição aberta
input bool            InpProtSoNoPrejuizo = false;      // Zerar só se a posição estiver perdendo
input int             InpProtPausaSeg     = 120;        // Segundos sem nova entrada depois de proteger
input bool            InpProtSoAvisar     = false;      // TESTE: só escreve no log, não cancela nem zera

//--- estado
CTrade   trade;
datetime g_ultimaBarra = 0;
ulong    g_ordem       = 0;
int      g_ordemBarras = 0;
bool     g_avisoFlags  = false;
datetime g_protegidoAte = 0;   // sem entrada nova antes dessa hora
datetime g_protUltSeg   = 0;   // protecao lida no maximo 1x por segundo
int      g_protAvisos   = 0;   // quantas vezes a protecao disparou hoje
datetime g_protDia      = 0;   // dia dos contadores
int      g_hMA          = INVALID_HANDLE;
int      g_hMC          = INVALID_HANDLE;   // média que cancela a limitada
ENUM_TIMEFRAMES g_mcTF  = PERIOD_CURRENT;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpUsarFiltroTend)
     {
      if(InpMATipo == MEDIA_ADAPTATIVA)
         g_hMA = iAMA(_Symbol, InpTFTendencia, InpAMAPeriodo, InpAMARapida, InpAMALenta, 0, InpMAPreco);
      else
         g_hMA = iMA(_Symbol, InpTFTendencia, InpMAPeriodo, 0, InpMAMetodo, PRICE_CLOSE);
      if(g_hMA == INVALID_HANDLE)
        {
         Print("Falha ao criar a média do filtro de tendência.");
         return(INIT_FAILED);
        }
     }
   if(InpCancelaMedia)
     {
      g_mcTF = (InpMCTF == PERIOD_CURRENT) ? InpTF : InpMCTF;
      if(InpMCTipo == MEDIA_ADAPTATIVA)
         g_hMC = iAMA(_Symbol, g_mcTF, InpMCAMAPeriodo, InpMCAMARapida, InpMCAMALenta, 0, InpMCPreco);
      else
         g_hMC = iMA(_Symbol, g_mcTF, InpMCPeriodo, 0, InpMCMetodo, PRICE_CLOSE);
      if(g_hMC == INVALID_HANDLE)
        {
         Print("Falha ao criar a média que cancela a limitada.");
         return(INIT_FAILED);
        }
     }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hMA != INVALID_HANDLE)
      IndicatorRelease(g_hMA);
   if(g_hMC != INVALID_HANDLE)
      IndicatorRelease(g_hMC);
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

//--- +1 alta, -1 baixa, 0 dentro da zona neutra (ou filtro desligado)
int Tendencia()
  {
   if(!InpUsarFiltroTend || g_hMA == INVALID_HANDLE)
      return 0;
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(g_hMA, 0, 0, 1, ma) < 1 || ma[0] <= 0)
      return 0;
   double preco = iClose(_Symbol, InpTFTendencia, 0);
   if(preco <= 0)
      return 0;
   double dist = preco - ma[0];
   if(MathAbs(dist) < Pts(InpMADistMin))
      return 0;
   return (dist > 0) ? +1 : -1;
  }

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
//+------------------------------------------------------------------+
//| Proteção: agressão ao vivo contra a mão do robô                   |
//+------------------------------------------------------------------+
//--- agressão dos últimos InpProtJanelaSeg segundos: +1, -1 ou 0
int AgressaoAgora(double &fator)
  {
   fator = 0;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTF, 1, InpMediaN, r) < InpMediaN)
      return 0;
   double soma = 0;
   for(int k = 0; k < InpMediaN; k++)
      soma += Vol(r[k]);
   double volNormalBarra = soma / InpMediaN;
   if(volNormalBarra <= 0)
      return 0;
   double volJanela = volNormalBarra * InpProtJanelaSeg / (double)PeriodSeconds(InpTF);
   if(volJanela <= 0)
      return 0;

   MqlTick tk[];
   ulong ate = (ulong)TimeCurrent() * 1000 + 999;
   ulong de  = ate - (ulong)InpProtJanelaSeg * 1000;
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE, de, ate);
   if(n < 2)
      return 0;

   bool temFlags = false;
   for(int i = 0; i < n && !temFlags; i++)
      if((tk[i].flags & (TICK_FLAG_BUY | TICK_FLAG_SELL)) != 0)
         temFlags = true;

   double vc = 0, vv = 0;
   double p0 = tk[0].last, mx = p0, mn = p0;
   int    ultimo = 0;
   for(int i = 0; i < n; i++)
     {
      int l = 0;
      if(temFlags)
        {
         bool b = (tk[i].flags & TICK_FLAG_BUY)  != 0;
         bool v = (tk[i].flags & TICK_FLAG_SELL) != 0;
         l = (b && !v) ? +1 : (v && !b) ? -1 : 0;
        }
      else
         if(i > 0)
           {
            l = (tk[i].last > tk[i-1].last) ? +1 : (tk[i].last < tk[i-1].last) ? -1 : ultimo;
            ultimo = l;
           }
      double vol = VolTick(tk[i]);
      if(l > 0)
         vc += vol;
      if(l < 0)
         vv += vol;
      if(tk[i].last > 0)
        {
         mx = MathMax(mx, tk[i].last);
         mn = MathMin(mn, tk[i].last);
        }
     }

   double total = vc + vv;
   fator = total / volJanela;
   if(total <= 0 || total < InpProtFator * volJanela)
      return 0;

   double niveis = InpProtNiveis * Tick();
   if(vc >= InpProtDominioPct / 100.0 * total && mx - p0 >= niveis - Tick() / 2)
      return +1;
   if(vv >= InpProtDominioPct / 100.0 * total && p0 - mn >= niveis - Tick() / 2)
      return -1;
   return 0;
  }

void ProtecaoAgressao()
  {
   if(!InpProtecao)
      return;

   //--- direção da posição e da ordem pendente
   ulong t[];
   int nPos = ListarPosicoes(t);
   int posDir = 0;
   if(nPos > 0 && PositionSelectByTicket(t[0]))
      posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? +1 : -1;
   int ordDir = 0;
   if(TemOrdem())
     {
      ENUM_ORDER_TYPE tp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ordDir = (tp == ORDER_TYPE_BUY_LIMIT || tp == ORDER_TYPE_BUY) ? +1 : -1;
     }
   if(posDir == 0 && ordDir == 0)
      return;

   datetime agora = TimeCurrent();
   if(agora == g_protUltSeg)
      return;
   g_protUltSeg = agora;

   double fator = 0;
   int ag = AgressaoAgora(fator);
   if(ag == 0)
      return;

   if(InicioDoDia(agora) != g_protDia)
     {
      g_protDia = InicioDoDia(agora);
      g_protAvisos = 0;
     }

   //--- posição com a agressão vindo contra
   if(posDir != 0 && ag == -posDir && InpProtZerar)
     {
      double pts = 0;
      if(PositionSelectByTicket(t[0]))
        {
         double ab = PositionGetDouble(POSITION_PRICE_OPEN);
         double at = PositionGetDouble(POSITION_PRICE_CURRENT);
         if(ab > 0 && at > 0)
            pts = posDir * (at - ab) / _Point;
        }
      if(!(InpProtSoNoPrejuizo && pts > 0))
        {
         g_protAvisos++;
         if(InpProtSoAvisar)
           {
            PrintFormat("PROTEÇÃO (SÓ AVISO %d): agressão %s de %.1fx contra a posição %s - ZERARIA em %.0f pontos",
                        g_protAvisos, (ag > 0 ? "de compra" : "de venda"), fator,
                        (posDir > 0 ? "comprada" : "vendida"), pts);
            return;
           }
         Zerar();
         g_protegidoAte = agora + InpProtPausaSeg;
         PrintFormat("PROTEÇÃO %d: agressão %s de %.1fx o volume contra a posição %s - zerado em %.0f pontos",
                     g_protAvisos, (ag > 0 ? "de compra" : "de venda"), fator,
                     (posDir > 0 ? "comprada" : "vendida"), pts);
         return;
        }
     }

   //--- ordem limitada que ia ser executada contra o fluxo
   if(ordDir != 0 && ag == -ordDir && InpProtCancelar)
     {
      g_protAvisos++;
      if(InpProtSoAvisar)
        {
         PrintFormat("PROTEÇÃO (SÓ AVISO %d): agressão %s de %.1fx contra a limitada %s - CANCELARIA a ordem",
                     g_protAvisos, (ag > 0 ? "de compra" : "de venda"), fator,
                     (ordDir > 0 ? "de compra" : "de venda"));
         return;
        }
      CancelarOrdem();
      g_ordemBarras = 0;
      g_protegidoAte = agora + InpProtPausaSeg;
      PrintFormat("PROTEÇÃO %d: agressão %s de %.1fx o volume contra a limitada %s - ordem cancelada",
                  g_protAvisos, (ag > 0 ? "de compra" : "de venda"), fator,
                  (ordDir > 0 ? "de compra" : "de venda"));
     }
  }

//+------------------------------------------------------------------+
void Entrar(int dir, double fechamento, double inicio)
  {
   //--- acabou de proteger: fica de fora pelo tempo da pausa
   if(InpProtecao && InpProtPausaSeg > 0 && TimeCurrent() < g_protegidoAte)
     {
      PrintFormat("Entrada ignorada: protegido por mais %d s", (int)(g_protegidoAte - TimeCurrent()));
      return;
     }

   //--- candle fechado do lado contrário: não manda a limitada
   if(InpCancelaMedia && g_hMC != INVALID_HANDLE)
     {
      double ma[];
      ArraySetAsSeries(ma, true);
      double c1 = iClose(_Symbol, g_mcTF, 1);
      if(CopyBuffer(g_hMC, 0, 1, 1, ma) >= 1 && ma[0] > 0 && c1 > 0)
        {
         double folga = Pts(InpMCFolga);
         if((dir < 0 && c1 > ma[0] + folga) || (dir > 0 && c1 < ma[0] - folga))
           {
            PrintFormat("Limitada de %s não enviada: candle fechou em %.0f, %s média (%.0f)",
                        (dir > 0 ? "compra" : "venda"), c1,
                        (dir < 0 ? "acima da" : "abaixo da"), ma[0]);
            return;
           }
        }
     }

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
//--- candle fechou do lado contrário da limitada pendente: cancela
bool CancelarContraMedia()
  {
   if(!InpCancelaMedia || g_hMC == INVALID_HANDLE || !TemOrdem())
      return false;
   ENUM_ORDER_TYPE tp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   int dir = (tp == ORDER_TYPE_BUY_LIMIT || tp == ORDER_TYPE_BUY) ? +1 : -1;

   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(g_hMC, 0, 1, 1, ma) < 1 || ma[0] <= 0)
      return false;
   double c1 = iClose(_Symbol, g_mcTF, 1);
   if(c1 <= 0)
      return false;

   double folga = Pts(InpMCFolga);
   bool contra = (dir < 0 && c1 > ma[0] + folga) ||
                 (dir > 0 && c1 < ma[0] - folga);
   if(!contra)
      return false;

   CancelarOrdem();
   g_ordemBarras = 0;
   PrintFormat("Limitada de %s cancelada: candle fechou em %.0f, %s a média (%.0f)",
               (dir > 0 ? "compra" : "venda"), c1,
               (dir < 0 ? "acima da" : "abaixo da"), ma[0]);
   return true;
  }

//+------------------------------------------------------------------+
void NovaBarra()
  {
   // candle contra a média cancela a limitada antes de contar a validade
   if(CancelarContraMedia())
      return;

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
   if(dir == 0)
      return;

   //--- filtro de tendência: não vende acima da média nem compra abaixo
   if(InpUsarFiltroTend)
     {
      int tend = Tendencia();
      if(tend != 0 && tend != dir)
        {
         PrintFormat("Entrada de %s barrada pelo filtro de tendência (mercado de %s)",
                     (dir > 0 ? "compra" : "venda"), (tend > 0 ? "alta" : "baixa"));
         return;
        }
     }

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

   ProtecaoAgressao();
   GerirTrailing();

   datetime barra = iTime(_Symbol, InpTF, 0);
   if(barra != g_ultimaBarra)
     {
      g_ultimaBarra = barra;
      NovaBarra();
     }
  }
//+------------------------------------------------------------------+
