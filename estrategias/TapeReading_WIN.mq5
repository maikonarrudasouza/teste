//+------------------------------------------------------------------+
//|                                             TapeReading_WIN.mq5   |
//|  Robô de leitura de fita para WIN, baseado em                     |
//|  "Studies in Tape Reading" (Wyckoff, 1910) e                      |
//|  "Tape Reading and Market Tactics" (Humphrey Neill, 1931):        |
//|   1. Clímax: volume muito alto num extremo SEM progresso de preço |
//|      (fecha longe do extremo) = oferta/demanda sendo absorvida.   |
//|   2. Teste: volta ao extremo do clímax com volume BAIXO e sem     |
//|      nova mínima/máxima relevante. Entrada na confirmação.        |
//|   3. Continuação: na tendência imediata, recuo "morno" (volume    |
//|      baixo) seguido de barra com volume e agressão a favor.       |
//|   4. Gestão: stop curto, zero a zero em 1R, aumenta a posição     |
//|      quando o mercado confirma, stop móvel nos fundos/topos,      |
//|      sai na hora se aparecer volume pesado contra, vira a mão no  |
//|      clímax oposto e nunca dorme posicionado.                     |
//+------------------------------------------------------------------+
#property copyright   "maikon arruda"
#property version     "1.00"
#property description "Tape Reading (Wyckoff 1910 + Neill) para WIN (B3)"

#include <Trade/Trade.mqh>

input group "Geral"
input ulong           InpMagic            = 191010;     // Número mágico
input double          InpLotes            = 1;          // Contratos na entrada inicial
input ENUM_TIMEFRAMES InpTF               = PERIOD_M1;  // Tempo gráfico da leitura

input group "Horário (hora do servidor)"
input string          InpInicio           = "09:10";    // Início das entradas
input string          InpFimEntradas      = "17:15";    // Fim das entradas
input string          InpZerar            = "17:50";    // Zerar tudo (não dorme posicionado)

input group "Volume"
input int             InpMediaN           = 30;         // Barras para a média de volume e range
input bool            InpUsarDelta        = true;       // Usar agressão (delta) dos ticks

input group "Setup 1: clímax + teste"
input bool            InpOperarClimax     = true;       // Ligar setup de clímax
input int             InpExtremoN         = 30;         // Clímax precisa ser a mín/máx das últimas N barras
input double          InpFatorClimax      = 2.5;        // Volume do clímax >= fator x média
input double          InpSemProgresso     = 0.40;       // Fecha a pelo menos isso do extremo (0..1 do range)
input int             InpJanelaTeste      = 10;         // Barras após o clímax para aparecer o teste
input double          InpFatorTeste       = 0.8;        // Volume do teste <= fator x média
input int             InpToleranciaTeste  = 30;         // Teste chega a até X pontos do extremo
input int             InpFuroMax          = 20;         // Teste pode furar o extremo em até X pontos

input group "Setup 2: continuação após recuo morno"
input bool            InpOperarRecuo      = true;       // Ligar setup de continuação
input int             InpEMA              = 21;         // Média que define a tendência imediata
input int             InpRecuoMin         = 2;          // Barras mínimas de recuo
input int             InpRecuoMax         = 8;          // Barras máximas de recuo
input double          InpFatorRecuo       = 0.8;        // Volume médio do recuo <= fator x média
input double          InpFatorGatilho     = 1.0;        // Volume da barra de retomada >= fator x média
input double          InpDeltaMinPct      = 10;         // Delta mínimo a favor (% do volume agredido)

input group "Gestão"
input int             InpFolgaStop        = 10;         // Folga além do stop (pontos)
input int             InpStopMin          = 40;         // Stop mínimo (pontos)
input int             InpStopMax          = 250;        // Stop máximo (pontos)
input double          InpAlvoR            = 3.0;        // Alvo final em R (0 = só stop móvel)
input bool            InpPiramidar        = true;       // Aumentar a posição quando confirmar
input double          InpLotesAdd         = 1;          // Contratos por aumento
input int             InpMaxAumentos      = 2;          // Máximo de aumentos (em +1R, +2R...)
input int             InpTrailN           = 5;          // Stop móvel na mín/máx das últimas N barras
input double          InpFatorSaida       = 2.0;        // Sai se volume >= fator x média contra a posição
input bool            InpVirarMao         = true;       // Vira a mão no clímax oposto
input int             InpValidadeOrdem    = 2;          // Barras que a ordem stop fica viva

input group "Limites do dia"
input int             InpMaxOperacoesDia  = 6;          // Máximo de entradas por dia (evita overtrading)
input double          InpPerdaMaxDia      = 300;        // Perda máxima do dia em R$ (0 = sem limite)
input int             InpPerdasSeguidas   = 3;          // Para no dia após N perdas seguidas (0 = não)

//--- estado
CTrade   trade;
int      g_ema         = INVALID_HANDLE;
datetime g_ultimaBarra = 0;
datetime g_dia         = 0;
bool     g_deltaOk     = true;
datetime g_climaxUsado = 0;

ulong    g_ordem       = 0;
int      g_ordemBarras = 0;

int      g_dir         = 0;     // posição em curso: +1 comprado, -1 vendido
double   g_entrada     = 0;     // preço da entrada inicial
double   g_risco       = 0;     // 1R em preço
int      g_aumentos    = 0;
bool     g_noZero      = false;

//--- cache de delta por barra
datetime g_cacheT[32];
double   g_cacheD[32];
double   g_cacheV[32];
int      g_cachePos    = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);
   g_ema = iMA(_Symbol, InpTF, InpEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_ema == INVALID_HANDLE)
      return(INIT_FAILED);
   ArrayInitialize(g_cacheT, 0);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_ema != INVALID_HANDLE)
      IndicatorRelease(g_ema);
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

// média de volume das N barras anteriores à barra i
double MediaVol(const MqlRates &r[], int i)
  {
   double s = 0;
   for(int k = i + 1; k <= i + InpMediaN; k++)
      s += Vol(r[k]);
   return s / InpMediaN;
  }

// posição do fechamento no range: 0 = na mínima, 1 = na máxima
double PosFech(const MqlRates &r)
  {
   double rg = r.high - r.low;
   return (rg > 0) ? (r.close - r.low) / rg : 0.5;
  }

//+------------------------------------------------------------------+
//| Delta de agressão da barra (ticks com flag de compra/venda)       |
//+------------------------------------------------------------------+
bool DeltaBarra(datetime t0, double &delta, double &volAgr)
  {
   for(int i = 0; i < 32; i++)
      if(g_cacheT[i] == t0)
        {
         delta = g_cacheD[i];
         volAgr = g_cacheV[i];
         return volAgr > 0;
        }

   delta = 0;
   volAgr = 0;
   MqlTick tk[];
   ulong de  = (ulong)t0 * 1000;
   ulong ate = (ulong)(t0 + PeriodSeconds(InpTF)) * 1000 - 1;
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE, de, ate);
   for(int i = 0; i < n; i++)
     {
      double v = (tk[i].volume_real > 0) ? tk[i].volume_real : (double)tk[i].volume;
      bool b = (tk[i].flags & TICK_FLAG_BUY)  != 0;
      bool s = (tk[i].flags & TICK_FLAG_SELL) != 0;
      if(b && !s)      { delta += v; volAgr += v; }
      else if(s && !b) { delta -= v; volAgr += v; }
     }
   if(n > 0)
     {
      g_cacheT[g_cachePos] = t0;
      g_cacheD[g_cachePos] = delta;
      g_cacheV[g_cachePos] = volAgr;
      g_cachePos = (g_cachePos + 1) % 32;
     }
   return volAgr > 0;
  }

// sinal do delta da barra: +1 compradores agrediram, -1 vendedores, 0 neutro/sem dado
int LadoAgressor(datetime t0)
  {
   if(!InpUsarDelta || !g_deltaOk)
      return 0;
   double d, va;
   if(!DeltaBarra(t0, d, va))
     {
      Print("Aviso: ticks sem flag de agressão; seguindo só com preço e volume.");
      g_deltaOk = false;
      return 0;
     }
   if(d >=  InpDeltaMinPct / 100.0 * va) return +1;
   if(d <= -InpDeltaMinPct / 100.0 * va) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Setup 1: clímax sem progresso + teste com volume baixo            |
//| dir=+1 procura fundo (clímax de venda), dir=-1 procura topo        |
//+------------------------------------------------------------------+
bool SetupClimax(const MqlRates &r[], int dir, double &entrada, double &stop, datetime &tClimax)
  {
   for(int c = 1; c <= InpJanelaTeste; c++)
     {
      // 1) extremo das últimas N barras
      bool extremo = true;
      for(int k = c + 1; k < c + InpExtremoN; k++)
        {
         if(dir > 0 && r[k].low  < r[c].low)  { extremo = false; break; }
         if(dir < 0 && r[k].high > r[c].high) { extremo = false; break; }
        }
      if(!extremo)
         continue;

      // 2) volume de clímax
      double media = MediaVol(r, c);
      if(media <= 0 || Vol(r[c]) < InpFatorClimax * media)
         continue;

      // 3) sem progresso: fechou longe do extremo
      double pos = PosFech(r[c]);
      if(dir > 0 && pos < InpSemProgresso)
         continue;
      if(dir < 0 && pos > 1.0 - InpSemProgresso)
         continue;

      if(r[c].time == g_climaxUsado)
         return false;

      double ext = (dir > 0) ? r[c].low : r[c].high;
      double tol = Pts(InpToleranciaTeste), furo = Pts(InpFuroMax);

      // nenhuma barra depois do clímax pode ter fechado além do extremo (o clímax falhou)
      bool falhou = false;
      for(int k = c - 1; k >= 0; k--)
        {
         if(dir > 0 && r[k].close < ext - furo) falhou = true;
         if(dir < 0 && r[k].close > ext + furo) falhou = true;
        }
      if(falhou)
         continue;

      // 4) teste: volta perto do extremo com volume baixo, sem furar muito
      int t = -1;
      for(int k = c - 1; k >= 0; k--)
        {
         bool perto = (dir > 0)
                      ? (r[k].low  <= ext + tol && r[k].low  >= ext - furo)
                      : (r[k].high >= ext - tol && r[k].high <= ext + furo);
         if(perto && Vol(r[k]) <= InpFatorTeste * media)
           {
            t = k;
            break;
           }
        }
      if(t < 0)
         continue;

      // 5) confirmação na última barra: fecha na metade a favor e agressão não contra
      if(dir > 0 && PosFech(r[0]) < 0.5)
         continue;
      if(dir < 0 && PosFech(r[0]) > 0.5)
         continue;
      if(LadoAgressor(r[0].time) == -dir)
         continue;

      double ref = ext;
      for(int k = c - 1; k >= 0; k--)
         ref = (dir > 0) ? MathMin(ref, r[k].low) : MathMax(ref, r[k].high);

      entrada = (dir > 0) ? Arred(r[0].high + Tick()) : Arred(r[0].low - Tick());
      stop    = (dir > 0) ? Arred(ref - Pts(InpFolgaStop)) : Arred(ref + Pts(InpFolgaStop));
      tClimax = r[c].time;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Setup 2: na tendência imediata, recuo morno + retomada com volume |
//+------------------------------------------------------------------+
bool SetupRecuo(const MqlRates &r[], const double &ema[], int dir, double &entrada, double &stop)
  {
   // tendência imediata: média inclinada a favor e preço do lado certo
   if(dir > 0 && !(ema[0] > ema[3] && r[0].close > ema[0]))
      return false;
   if(dir < 0 && !(ema[0] < ema[3] && r[0].close < ema[0]))
      return false;

   // topo (ou fundo) do impulso entre as barras 1..RecuoMax+1
   int j = 1;
   for(int k = 2; k <= InpRecuoMax + 1; k++)
     {
      if(dir > 0 && r[k].high > r[j].high) j = k;
      if(dir < 0 && r[k].low  < r[j].low)  j = k;
     }
   int barrasRecuo = j - 1;                  // barras 1..j-1 são o recuo
   if(barrasRecuo < InpRecuoMin)
      return false;

   // recuo morno: volume baixo e sem agressão forte contra
   double media = MediaVol(r, j);
   double somaV = 0;
   double ref = (dir > 0) ? r[1].low : r[1].high;
   for(int k = 1; k < j; k++)
     {
      somaV += Vol(r[k]);
      ref = (dir > 0) ? MathMin(ref, r[k].low) : MathMax(ref, r[k].high);
     }
   if(media <= 0 || somaV / barrasRecuo > InpFatorRecuo * media)
      return false;

   // o recuo não pode ter perdido a média
   if(dir > 0 && ref < ema[j - 1] - Pts(InpToleranciaTeste))
      return false;
   if(dir < 0 && ref > ema[j - 1] + Pts(InpToleranciaTeste))
      return false;

   // barra de retomada: rompe a barra anterior, volume e agressão a favor, fecha no terço extremo
   if(dir > 0 && !(r[0].close > r[1].high && PosFech(r[0]) >= 0.67))
      return false;
   if(dir < 0 && !(r[0].close < r[1].low && PosFech(r[0]) <= 0.33))
      return false;
   if(Vol(r[0]) < InpFatorGatilho * MediaVol(r, 0))
      return false;
   int lado = LadoAgressor(r[0].time);
   if(InpUsarDelta && g_deltaOk && lado != dir)
      return false;

   ref = (dir > 0) ? MathMin(ref, r[0].low) : MathMax(ref, r[0].high);
   entrada = (dir > 0) ? Arred(r[0].high + Tick()) : Arred(r[0].low - Tick());
   stop    = (dir > 0) ? Arred(ref - Pts(InpFolgaStop)) : Arred(ref + Pts(InpFolgaStop));
   return true;
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
      // perdas seguidas: saídas mais recentes primeiro
      if(contando && (tipo == DEAL_ENTRY_OUT || tipo == DEAL_ENTRY_INOUT))
        {
         if(res < 0) perdasSeguidas++;
         else        contando = false;
        }
     }
  }

bool TemPosicao()
  {
   return PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == (long)InpMagic;
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
   if(TemPosicao())
      trade.PositionClose(_Symbol);
   g_dir = 0;
  }

//+------------------------------------------------------------------+
//| Envia ordem stop de entrada                                       |
//+------------------------------------------------------------------+
bool Entrar(int dir, double entrada, double stop, string nome)
  {
   double risco = dir * (entrada - stop);
   if(risco < Pts(InpStopMin))
     {
      stop = Arred(entrada - dir * Pts(InpStopMin));
      risco = Pts(InpStopMin);
     }
   if(risco > Pts(InpStopMax))
     {
      PrintFormat("%s ignorado: stop de %.0f pts acima do máximo", nome, risco / _Point);
      return false;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((dir > 0 && ask >= entrada) || (dir < 0 && bid <= entrada))
     {
      PrintFormat("%s ignorado: preço já passou da entrada", nome);
      return false;
     }

   double alvo = (InpAlvoR > 0) ? Arred(entrada + dir * InpAlvoR * risco) : 0;
   bool ok = (dir > 0)
             ? trade.BuyStop(InpLotes, entrada, _Symbol, stop, alvo, ORDER_TIME_DAY, 0, "TR " + nome)
             : trade.SellStop(InpLotes, entrada, _Symbol, stop, alvo, ORDER_TIME_DAY, 0, "TR " + nome);
   if(!ok || trade.ResultOrder() == 0)
     {
      PrintFormat("%s: falha ao enviar ordem (%u %s)", nome, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
     }
   g_ordem       = trade.ResultOrder();
   g_ordemBarras = 0;
   g_dir         = dir;
   g_entrada     = entrada;
   g_risco       = risco;
   g_aumentos    = 0;
   g_noZero      = false;
   PrintFormat("%s: %s stop %.0f | SL %.0f | alvo %.0f | risco %.0f pts",
               nome, dir > 0 ? "compra" : "venda", entrada, stop, alvo, risco / _Point);
   return true;
  }

//+------------------------------------------------------------------+
//| Gestão a cada tick: zero a zero e aumentos a cada +1R             |
//+------------------------------------------------------------------+
void GerirTick()
  {
   if(!TemPosicao() || g_dir == 0 || g_risco <= 0)
      return;
   if(TemOrdem())
      CancelarOrdem();

   double preco = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double ganhoR = g_dir * (preco - g_entrada) / g_risco;

   if(!g_noZero && ganhoR >= 1.0)
     {
      double tp = PositionGetDouble(POSITION_TP);
      if(trade.PositionModify(_Symbol, Arred(g_entrada), tp))
         g_noZero = true;
     }

   // o mercado confirmou: aumenta a posição com o risco já protegido
   if(InpPiramidar && g_noZero && g_aumentos < InpMaxAumentos && ganhoR >= 1.0 + g_aumentos)
     {
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      bool ok = (g_dir > 0)
                ? trade.Buy(InpLotesAdd, _Symbol, 0, sl, tp, "TR aumento")
                : trade.Sell(InpLotesAdd, _Symbol, 0, sl, tp, "TR aumento");
      g_aumentos++;   // conta mesmo se falhar, para não insistir a cada tick
      if(!ok)
         PrintFormat("Aumento falhou (%u)", trade.ResultRetcode());
      else if(PositionSelect(_Symbol))
        {
         // com o preço médio novo, o stop sobe para o médio: o aumento também fica protegido
         double medio = Arred(PositionGetDouble(POSITION_PRICE_OPEN));
         double slAt  = PositionGetDouble(POSITION_SL);
         if(g_dir * (medio - slAt) > 0 && g_dir * (preco - medio) > Tick())
            trade.PositionModify(_Symbol, medio, PositionGetDouble(POSITION_TP));
        }
     }
  }

//+------------------------------------------------------------------+
//| Gestão no fechamento da barra: saída por volume contra e stop     |
//| móvel                                                             |
//+------------------------------------------------------------------+
bool GerirBarra(const MqlRates &r[])
  {
   if(!TemPosicao())
     {
      if(!TemOrdem())
         g_dir = 0;
      return false;
     }
   int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? +1 : -1;
   g_dir = dir;

   // volume pesado contra a posição: sai na hora (Neill)
   double media = MediaVol(r, 0);
   bool pesado = Vol(r[0]) >= InpFatorSaida * media;
   bool contra = (dir > 0) ? (PosFech(r[0]) <= 0.33 && r[0].close < r[1].low)
                           : (PosFech(r[0]) >= 0.67 && r[0].close > r[1].high);
   int lado = LadoAgressor(r[0].time);
   if(pesado && contra && lado != dir)
     {
      Print("Saída: volume pesado contra a posição");
      trade.PositionClose(_Symbol);
      g_dir = 0;
      return true;
     }

   // stop móvel nas mínimas/máximas recentes depois do zero a zero
   if(g_noZero)
     {
      double ref = (dir > 0) ? r[0].low : r[0].high;
      for(int k = 1; k < InpTrailN; k++)
         ref = (dir > 0) ? MathMin(ref, r[k].low) : MathMax(ref, r[k].high);
      double novo = Arred(ref - dir * Pts(InpFolgaStop));
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double preco = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(dir * (novo - sl) > 0 && dir * (preco - novo) > Tick())
         trade.PositionModify(_Symbol, novo, tp);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Lógica de cada barra fechada                                      |
//+------------------------------------------------------------------+
void NovaBarra()
  {
   int precisa = InpMediaN + MathMax(InpExtremoN, InpRecuoMax) + InpJanelaTeste + 5;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTF, 1, precisa, r) < precisa)
      return;
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_ema, 0, 1, InpRecuoMax + 5, ema) < InpRecuoMax + 5)
      return;

   bool saiu = GerirBarra(r);

   // validade da ordem stop
   if(TemOrdem())
     {
      g_ordemBarras++;
      if(g_ordemBarras >= InpValidadeOrdem)
        {
         CancelarOrdem();
         g_dir = 0;
        }
      return;
     }
   g_ordem = 0;
   if(saiu)
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

   bool posicionado = TemPosicao();
   int dirPos = posicionado ? g_dir : 0;
   double e, s;
   datetime tc;

   // clímax: entrada nova ou virada de mão contra a posição atual
   if(InpOperarClimax)
     {
      for(int dir = +1; dir >= -1; dir -= 2)
        {
         if(posicionado && (dir == dirPos || !InpVirarMao))
            continue;
         if(!SetupClimax(r, dir, e, s, tc))
            continue;
         if(posicionado)
           {
            Print("Virando a mão: clímax contra a posição");
            trade.PositionClose(_Symbol);
           }
         g_climaxUsado = tc;
         Entrar(dir, e, s, dir > 0 ? "Clímax de venda + teste" : "Clímax de compra + teste");
         return;
        }
     }

   if(posicionado)
      return;

   if(InpOperarRecuo)
     {
      if(SetupRecuo(r, ema, +1, e, s)) { Entrar(+1, e, s, "Recuo morno na alta"); return; }
      if(SetupRecuo(r, ema, -1, e, s)) { Entrar(-1, e, s, "Recuo morno na baixa"); return; }
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime hoje = InicioDoDia(TimeCurrent());
   if(hoje != g_dia)
     {
      g_dia = hoje;
      g_deltaOk = true;
     }

   if(MinutosAgora() >= Minutos(InpZerar))
     {
      Zerar();
      return;
     }

   GerirTick();

   datetime barra = iTime(_Symbol, InpTF, 0);
   if(barra != g_ultimaBarra)
     {
      g_ultimaBarra = barra;
      NovaBarra();
     }
  }
//+------------------------------------------------------------------+
