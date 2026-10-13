//+------------------------------------------------------------------+
//|                                               Wyckoff20_FX.mq5    |
//|  Robô intradiário para WIN baseado nos princípios do livro        |
//|  "Wyckoff 2.0" (Rubén Villahermosa):                              |
//|   1. Contexto: preço dentro, aceito acima ou aceito abaixo da     |
//|      área de valor da sessão anterior.                            |
//|   2. Onde: VAH, VAL e VWAP da sessão (níveis operacionais).       |
//|   3. Gatilho: barra SOS/SOW (range amplo, fechamento no terço     |
//|      extremo, volume alto) com delta de agressão a favor.         |
//|   4. Entrada por ordem stop acima/abaixo da barra de gatilho,     |
//|      stop do outro lado da barra ou do nível, alvos nos próximos  |
//|      níveis de alto volume (VPOC, extremos da VA, VPOCs nus).     |
//+------------------------------------------------------------------+
#property copyright   "maikon arruda"
#property version     "1.00"
#property description "Wyckoff 2.0 + Volume Profile para forex (EURUSD)"

#include <Trade/Trade.mqh>

enum ENUM_MODO_STOP
  {
   STOP_BARRA = 0,   // Do outro lado da barra de gatilho
   STOP_NIVEL = 1    // Do outro lado do nível testado (mais largo)
  };

input group "Geral"
input ulong           InpMagic            = 202011;     // Número mágico
input double          InpLotes            = 0.10;       // Lotes por entrada
input ENUM_TIMEFRAMES InpTFGatilho        = PERIOD_M5;  // Tempo gráfico do gatilho

input group "Horário (hora do servidor)"
input string          InpInicio           = "10:00";    // Início das entradas (abertura de Londres em servidor GMT+3)
input string          InpFimEntradas      = "19:00";    // Fim das entradas
input string          InpZerar            = "23:30";    // Zerar tudo

input group "Perfil de volume"
input int             InpPassoPerfil      = 10;         // Tamanho de cada faixa do perfil (pontos; 10 = 1 pip)
input double          InpAreaValorPct     = 70;         // Área de valor (% do volume)
input int             InpSessoesNaked     = 5;          // Sessões antigas para procurar VPOC nu

input group "Contexto"
input int             InpBarrasAceitacao  = 3;          // Fechamentos seguidos para aceitar fora/dentro da VA
input bool            InpOperarRange      = true;       // Dentro da VA: comprar na VAL e vender na VAH
input bool            InpOperarContinuacao= true;       // Fora da VA: teste da VAH/VAL rompida
input bool            InpOperarVWAP       = true;       // Fora da VA: recuo até a VWAP da sessão

input group "Zona e gatilho"
input int             InpTolerancia       = 30;         // Distância do nível que conta como teste (pontos)
input int             InpPenetracaoMax    = 100;        // Quanto pode furar o nível e ainda valer (pontos)
input int             InpBarrasArmado     = 3;          // Barras após o teste para aparecer o gatilho
input int             InpMediaN           = 20;         // Barras para médias de range e volume
input double          InpFatorRange       = 1.2;        // Range da barra >= fator x range médio
input double          InpFatorVolume      = 1.3;        // Volume da barra >= fator x volume médio
input double          InpTercoFech        = 0.33;       // Fechamento no terço extremo (0.33)
input bool            InpUsarDelta        = false;      // Exigir delta de agressão (forex não tem: deixe desligado)
input double          InpDeltaMinPct      = 10;         // Delta mínimo (% do volume agredido)
input bool            InpExigirAbsorcao   = false;      // Exigir absorção antes do gatilho
input double          InpFatorAbsorcao    = 1.3;        // Absorção: volume >= fator x média
input double          InpPavioMin         = 0.4;        // Absorção: pavio de rejeição >= fração do range
input int             InpValidadeOrdem    = 2;          // Barras que a ordem stop fica viva

input group "Stop e alvo fixos"
input bool            InpFixo             = true;       // Usar stop e alvo fixos (desliga parcial e alvos por nível)
input int             InpStopFixo         = 150;        // Stop fixo (pontos; 150 = 15 pips)
input int             InpAlvoFixo         = 300;        // Alvo fixo (pontos; 300 = 30 pips)

input group "Risco e alvos"
input ENUM_MODO_STOP  InpModoStop         = STOP_BARRA; // Onde fica o stop
input int             InpFolgaStop        = 20;         // Folga além do stop (pontos)
input int             InpStopMax          = 250;        // Stop máximo (pontos)
input double          InpRRMin            = 1.5;        // Risco:retorno mínimo até o alvo final
input double          InpAlvoRSemNivel    = 2.0;        // Alvo em R quando não há nível à frente
input bool            InpParcial          = true;       // Realizar parcial no 1º alvo e ir para o zero a zero
input double          InpParcialPct       = 50;         // % da posição na parcial
input int             InpMaxOperacoesDia  = 3;          // Máximo de entradas por dia
input double          InpPerdaMaxDia      = 100;        // Perda máxima do dia na moeda da conta (0 = sem limite)
input bool            InpDesenharNiveis   = true;       // Desenhar níveis no gráfico

//--- estado
struct Perfil
  {
   double            poc, vah, val, hi, lo;
   bool              ok;
  };

enum ENUM_REGIME { REG_NEUTRO = 0, REG_DENTRO, REG_ACIMA, REG_ABAIXO };

CTrade   trade;
Perfil   g_prev;
double   g_naked[];
double   g_vwap        = 0;
datetime g_dia         = 0;
datetime g_ultimaBarra = 0;
bool     g_deltaDisponivel = true;
bool     g_avisoDelta  = false;

//--- ordem pendente e posição em curso
ulong    g_ordem       = 0;
int      g_ordemBarras = 0;
int      g_dir         = 0;
double   g_entrada     = 0;
double   g_alvo1       = 0;
bool     g_parcialFeita= false;

//--- cache de delta por barra
datetime g_cacheT[16];
double   g_cacheD[16];
double   g_cacheV[16];
int      g_cachePos    = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);
   ArrayInitialize(g_cacheT, 0);
   g_prev.ok = false;
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "W20_");
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

datetime InicioDoDia(datetime t)
  {
   return t - (t % 86400);
  }

double VolumeBarra(const MqlRates &r)
  {
   return (r.real_volume > 0) ? (double)r.real_volume : (double)r.tick_volume;
  }

//+------------------------------------------------------------------+
//| Perfil de volume a partir de barras M1                            |
//| (o volume de cada minuto é distribuído pelas faixas do seu range) |
//+------------------------------------------------------------------+
bool CalcPerfil(datetime de, datetime ate, Perfil &p)
  {
   p.ok = false;
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, de, ate, r);
   if(n <= 0)
      return false;

   double lo = DBL_MAX, hi = -DBL_MAX;
   for(int i = 0; i < n; i++)
     {
      lo = MathMin(lo, r[i].low);
      hi = MathMax(hi, r[i].high);
     }
   double passo = Pts(MathMax(1, InpPassoPerfil));
   int nb = (int)MathFloor((hi - lo) / passo + 1e-9) + 1;
   if(nb < 1 || nb > 50000)
      return false;

   double vol[];
   ArrayResize(vol, nb);
   ArrayInitialize(vol, 0);
   double total = 0;
   for(int i = 0; i < n; i++)
     {
      double v = VolumeBarra(r[i]);
      int a = (int)MathFloor((r[i].low  - lo) / passo + 1e-9);
      int b = (int)MathFloor((r[i].high - lo) / passo + 1e-9);
      a = MathMax(0, MathMin(nb - 1, a));
      b = MathMax(0, MathMin(nb - 1, b));
      double q = v / (b - a + 1);
      for(int j = a; j <= b; j++)
         vol[j] += q;
      total += v;
     }
   if(total <= 0)
      return false;

   int poc = ArrayMaximum(vol);
   double alvo = total * InpAreaValorPct / 100.0;
   double acum = vol[poc];
   int up = poc, dn = poc;
   while(acum < alvo && (up < nb - 1 || dn > 0))
     {
      double vu = (up < nb - 1) ? vol[up + 1] : -1;
      double vd = (dn > 0)      ? vol[dn - 1] : -1;
      if(vu >= vd) { up++; acum += vol[up]; }
      else         { dn--; acum += vol[dn]; }
     }
   p.poc = Arred(lo + poc * passo);
   p.vah = Arred(lo + up  * passo);
   p.val = Arred(lo + dn  * passo);
   p.hi  = hi;
   p.lo  = lo;
   p.ok  = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Recalcula perfil da sessão anterior e VPOCs nus (1x por dia)      |
//+------------------------------------------------------------------+
void NovoDia()
  {
   datetime hoje = InicioDoDia(TimeCurrent());
   g_prev.ok = false;
   ArrayResize(g_naked, 0);

   // localizar o índice D1 da sessão anterior (primeira barra D1 antes de hoje)
   int idxPrev = -1;
   for(int i = 0; i < 10; i++)
     {
      datetime t = iTime(_Symbol, PERIOD_D1, i);
      if(t == 0)
         break;
      if(t < hoje) { idxPrev = i; break; }
     }
   if(idxPrev < 0)
      return;

   datetime tPrev = iTime(_Symbol, PERIOD_D1, idxPrev);
   if(!CalcPerfil(tPrev, tPrev + 86399, g_prev))
      return;

   // VPOCs nus: VPOC de sessões antigas que o preço nunca mais tocou
   for(int k = idxPrev + 1; k <= idxPrev + InpSessoesNaked; k++)
     {
      datetime tk = iTime(_Symbol, PERIOD_D1, k);
      if(tk == 0)
         break;
      Perfil pk;
      if(!CalcPerfil(tk, tk + 86399, pk))
         continue;
      int iMax = iHighest(_Symbol, PERIOD_D1, MODE_HIGH, k, 0);
      int iMin = iLowest(_Symbol, PERIOD_D1, MODE_LOW, k, 0);
      if(iMax < 0 || iMin < 0)
         continue;
      double maxH = iHigh(_Symbol, PERIOD_D1, iMax);
      double minL = iLow(_Symbol, PERIOD_D1, iMin);
      if(pk.poc > maxH || pk.poc < minL)
        {
         int s = ArraySize(g_naked);
         ArrayResize(g_naked, s + 1);
         g_naked[s] = pk.poc;
        }
     }
  }

//+------------------------------------------------------------------+
//| VWAP da sessão atual (barras M1) e limpeza dos VPOCs nus tocados  |
//+------------------------------------------------------------------+
void AtualizarSessao()
  {
   datetime hoje = InicioDoDia(TimeCurrent());
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, hoje, TimeCurrent(), r);
   if(n <= 0)
      return;
   double pv = 0, v = 0, hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < n; i++)
     {
      double vb = VolumeBarra(r[i]);
      pv += vb * (r[i].high + r[i].low + r[i].close) / 3.0;
      v  += vb;
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
     }
   if(v > 0)
      g_vwap = Arred(pv / v);

   for(int i = ArraySize(g_naked) - 1; i >= 0; i--)
      if(g_naked[i] <= hi && g_naked[i] >= lo)
         ArrayRemove(g_naked, i, 1);
  }

//+------------------------------------------------------------------+
//| Delta de agressão da barra (ticks com flag de compra/venda)       |
//+------------------------------------------------------------------+
bool DeltaBarra(datetime t0, double &delta, double &volAgr)
  {
   for(int i = 0; i < 16; i++)
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
   ulong ate = (ulong)(t0 + PeriodSeconds(InpTFGatilho)) * 1000 - 1;
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
      g_cachePos = (g_cachePos + 1) % 16;
     }
   return volAgr > 0;
  }

//+------------------------------------------------------------------+
//| Regime do dia em relação à área de valor anterior                 |
//| (r[] em série: r[0] = última barra fechada)                       |
//+------------------------------------------------------------------+
ENUM_REGIME Regime(const MqlRates &r[], int nHoje)
  {
   ENUM_REGIME reg = REG_NEUTRO;
   int acima = 0, abaixo = 0, dentro = 0;
   for(int i = nHoje - 1; i >= 0; i--)
     {
      double c = r[i].close;
      if(c > g_prev.vah)      { acima++;  abaixo = 0; dentro = 0; }
      else if(c < g_prev.val) { abaixo++; acima = 0;  dentro = 0; }
      else                    { dentro++; acima = 0;  abaixo = 0; }
      if(acima  >= InpBarrasAceitacao) reg = REG_ACIMA;
      if(abaixo >= InpBarrasAceitacao) reg = REG_ABAIXO;
      if(dentro >= InpBarrasAceitacao) reg = REG_DENTRO;
     }
   return reg;
  }

//+------------------------------------------------------------------+
//| Barra de intenção (SOS para dir=+1, SOW para dir=-1)              |
//+------------------------------------------------------------------+
bool BarraIntencao(const MqlRates &r[], int i, int dir)
  {
   double range = r[i].high - r[i].low;
   if(range <= 0)
      return false;

   double somaR = 0, somaV = 0;
   for(int k = i + 1; k <= i + InpMediaN; k++)
     {
      somaR += r[k].high - r[k].low;
      somaV += VolumeBarra(r[k]);
     }
   double mediaR = somaR / InpMediaN;
   double mediaV = somaV / InpMediaN;
   if(range < InpFatorRange * mediaR)
      return false;
   if(VolumeBarra(r[i]) < InpFatorVolume * mediaV)
      return false;

   double pos = (r[i].close - r[i].low) / range;   // 0 = mínima, 1 = máxima
   if(dir > 0 && pos < 1.0 - InpTercoFech)
      return false;
   if(dir < 0 && pos > InpTercoFech)
      return false;

   if(InpUsarDelta && g_deltaDisponivel)
     {
      double d, va;
      if(DeltaBarra(r[i].time, d, va))
        {
         if(dir * d < InpDeltaMinPct / 100.0 * va)
            return false;
        }
      else if(!g_avisoDelta)
        {
         // corretora sem flag de agressor nos ticks: segue só com preço e volume
         Print("Aviso: ticks sem flag de agressão; filtro de delta desligado.");
         g_avisoDelta = true;
         g_deltaDisponivel = false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Absorção antes do gatilho: barra perto do nível, com volume alto, |
//| que não conseguiu seguir contra nós. Na compra: pavio inferior    |
//| grande e fechamento na metade de cima (vendas absorvidas por      |
//| ordens limitadas). No forex não há delta, então vale preço +      |
//| volume de ticks; se houver delta, exige também agressão contra.   |
//+------------------------------------------------------------------+
bool Absorcao(const MqlRates &r[], int de, int ate, int dir, double nivel)
  {
   double tol = Pts(InpTolerancia), pen = Pts(InpPenetracaoMax);
   for(int i = de; i <= ate; i++)
     {
      double range = r[i].high - r[i].low;
      if(range <= 0)
         continue;
      bool perto = (dir > 0) ? (r[i].low  <= nivel + tol && r[i].low  >= nivel - pen)
                             : (r[i].high >= nivel - tol && r[i].high <= nivel + pen);
      if(!perto)
         continue;

      double somaV = 0;
      for(int k = i + 1; k <= i + InpMediaN; k++)
         somaV += VolumeBarra(r[k]);
      if(VolumeBarra(r[i]) < InpFatorAbsorcao * somaV / InpMediaN)
         continue;

      double pos   = (r[i].close - r[i].low) / range;
      double pavio = (dir > 0) ? (MathMin(r[i].open, r[i].close) - r[i].low) / range
                               : (r[i].high - MathMax(r[i].open, r[i].close)) / range;
      bool naoAndou = (dir > 0) ? (pos >= 0.5) : (pos <= 0.5);
      if(!naoAndou || pavio < InpPavioMin)
         continue;

      if(InpUsarDelta && g_deltaDisponivel)
        {
         double d, va;
         if(DeltaBarra(r[i].time, d, va) && (-dir * d) < InpDeltaMinPct / 100.0 * va)
            continue;
        }
      return true;
     }
   return false;
  }


//+------------------------------------------------------------------+
//| Procura teste do nível + gatilho. Retorna true e preenche extremo |
//+------------------------------------------------------------------+
bool Setup(const MqlRates &r[], int nHoje, double nivel, int dir, double &extremo)
  {
   if(nivel <= 0)
      return false;
   double tol = Pts(InpTolerancia), pen = Pts(InpPenetracaoMax);

   // gatilho na última barra fechada, voltando para o lado certo do nível
   if(dir > 0 && r[0].close <= nivel)
      return false;
   if(dir < 0 && r[0].close >= nivel)
      return false;
   if(!BarraIntencao(r, 0, dir))
      return false;

   int lim = MathMin(InpBarrasArmado, nHoje) - 1;
   for(int t = 0; t <= lim; t++)
     {
      bool toque = (dir > 0)
                   ? (r[t].low  <= nivel + tol && r[t].low  >= nivel - pen)
                   : (r[t].high >= nivel - tol && r[t].high <= nivel + pen);
      if(!toque)
         continue;

      // nenhuma barra entre o teste e o gatilho pode ter fechado além da penetração
      bool valido = true;
      extremo = (dir > 0) ? r[t].low : r[t].high;
      for(int k = t; k >= 0; k--)
        {
         if(dir > 0 && r[k].close < nivel - pen) valido = false;
         if(dir < 0 && r[k].close > nivel + pen) valido = false;
         extremo = (dir > 0) ? MathMin(extremo, r[k].low) : MathMax(extremo, r[k].high);
        }
      if(!valido)
         continue;

      // absorção nas barras antes do gatilho (do teste até a barra anterior à SOS/SOW)
      if(InpExigirAbsorcao && !Absorcao(r, 1, MathMax(t, 1), dir, nivel))
         continue;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Alvos: próximos níveis de volume na direção da operação           |
//+------------------------------------------------------------------+
void Alvos(int dir, double entrada, double risco, double &a1, double &a2)
  {
   int nNaked = ArraySize(g_naked);
   int n = 6 + nNaked;
   double niveis[];
   ArrayResize(niveis, n);
   niveis[0] = g_prev.poc;
   niveis[1] = g_prev.vah;
   niveis[2] = g_prev.val;
   niveis[3] = g_prev.hi;
   niveis[4] = g_prev.lo;
   niveis[5] = g_vwap;
   for(int i = 0; i < nNaked; i++)
      niveis[6 + i] = g_naked[i];

   double minDist = 0.5 * risco;
   a1 = 0;
   a2 = 0;
   // ordena pela distância na direção da operação
   double cand[];
   int m = 0;
   for(int i = 0; i < n; i++)
     {
      double dist = dir * (niveis[i] - entrada);
      if(niveis[i] > 0 && dist >= minDist)
        {
         ArrayResize(cand, m + 1);
         cand[m++] = dist;
        }
     }
   if(m > 0)
     {
      ArraySort(cand);
      a1 = entrada + dir * cand[0];
      a2 = (m > 1) ? entrada + dir * cand[1] : a1;
     }
   else
     {
      a1 = entrada + dir * risco;
      a2 = entrada + dir * InpAlvoRSemNivel * risco;
     }
   a1 = Arred(a1);
   a2 = Arred(a2);
  }

//+------------------------------------------------------------------+
//| Controle diário: entradas e resultado do robô hoje                |
//+------------------------------------------------------------------+
void ResumoDia(int &entradas, double &resultado)
  {
   entradas = 0;
   resultado = 0;
   if(!HistorySelect(InicioDoDia(TimeCurrent()), TimeCurrent() + 60))
      return;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      long tipo = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(tipo == DEAL_ENTRY_IN)
         entradas++;
      resultado += HistoryDealGetDouble(d, DEAL_PROFIT)
                   + HistoryDealGetDouble(d, DEAL_COMMISSION)
                   + HistoryDealGetDouble(d, DEAL_SWAP);
     }
  }

//--- posições do robô (funciona em conta netting e hedging)
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
   if(ListarPosicoes(t) == 0)
      return false;
   return PositionSelectByTicket(t[0]);
  }

void FecharPosicoes()
  {
   ulong t[];
   int n = ListarPosicoes(t);
   for(int i = 0; i < n; i++)
      trade.PositionClose(t[i]);
  }

// muda o stop de todas as posições do robô, mantendo o alvo de cada uma
bool MudarStop(double sl)
  {
   ulong t[];
   int n = ListarPosicoes(t);
   bool ok = n > 0;
   for(int i = 0; i < n; i++)
      if(PositionSelectByTicket(t[i]))
         ok = trade.PositionModify(t[i], sl, PositionGetDouble(POSITION_TP)) && ok;
   return ok;
  }

// preço médio e volume total das posições do robô
double PrecoMedio(double &volTotal)
  {
   ulong t[];
   int n = ListarPosicoes(t);
   double pv = 0;
   volTotal = 0;
   for(int i = 0; i < n; i++)
      if(PositionSelectByTicket(t[i]))
        {
         double v = PositionGetDouble(POSITION_VOLUME);
         volTotal += v;
         pv += v * PositionGetDouble(POSITION_PRICE_OPEN);
        }
   return (volTotal > 0) ? pv / volTotal : 0;
  }

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

bool TemOrdem()
  {
   return g_ordem != 0 && OrderSelect(g_ordem);
  }

void Zerar()
  {
   if(TemOrdem())
      trade.OrderDelete(g_ordem);
   g_ordem = 0;
   if(TemPosicao())
      FecharPosicoes();
  }

//+------------------------------------------------------------------+
//| Envia ordem stop de entrada                                       |
//+------------------------------------------------------------------+
void Entrar(const MqlRates &r[], int dir, double nivel, double extremo, string nome)
  {
   double t = Tick();
   double entrada, sl;
   if(dir > 0)
     {
      entrada = Arred(r[0].high + t);
      double ref = (InpModoStop == STOP_BARRA) ? r[0].low : MathMin(extremo, nivel);
      sl = Arred(ref - Pts(InpFolgaStop));
     }
   else
     {
      entrada = Arred(r[0].low - t);
      double ref = (InpModoStop == STOP_BARRA) ? r[0].high : MathMax(extremo, nivel);
      sl = Arred(ref + Pts(InpFolgaStop));
     }
   if(InpFixo)
      sl = Arred(entrada - dir * Pts(InpStopFixo));
   double risco = dir * (entrada - sl);
   if(risco <= 0 || (!InpFixo && risco > Pts(InpStopMax)))
     {
      PrintFormat("%s ignorado: risco %.0f pts fora do limite", nome, risco / _Point);
      return;
     }

   double a1, a2;
   Alvos(dir, entrada, risco, a1, a2);
   if(InpFixo)
     {
      a1 = 0;                                   // sem parcial
      a2 = Arred(entrada + dir * Pts(InpAlvoFixo));
     }
   double rr = dir * (a2 - entrada) / risco;
   if(!InpFixo && rr < InpRRMin)
     {
      PrintFormat("%s ignorado: R:R %.2f abaixo do mínimo", nome, rr);
      return;
     }

   // não persegue preço: se já passou do ponto de entrada, deixa ir
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((dir > 0 && ask >= entrada) || (dir < 0 && bid <= entrada))
     {
      PrintFormat("%s ignorado: preço já passou da entrada", nome);
      return;
     }

   double lote = Lote(InpLotes);
   bool ok = (dir > 0)
             ? trade.BuyStop(lote, entrada, _Symbol, sl, a2, ORDER_TIME_GTC, 0, "W20 " + nome)
             : trade.SellStop(lote, entrada, _Symbol, sl, a2, ORDER_TIME_GTC, 0, "W20 " + nome);
   if(ok && trade.ResultOrder() > 0)
     {
      g_ordem        = trade.ResultOrder();
      g_ordemBarras  = 0;
      g_dir          = dir;
      g_entrada      = entrada;
      g_alvo1        = a1;
      g_parcialFeita = false;
      PrintFormat("%s: %s stop %.5f | SL %.5f | alvo1 %.5f | alvo2 %.5f | R:R %.2f",
                  nome, dir > 0 ? "compra" : "venda", entrada, sl, a1, a2, rr);
     }
   else
      PrintFormat("%s: falha ao enviar ordem (%u %s)", nome, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Desenho dos níveis                                                |
//+------------------------------------------------------------------+
void Linha(string nome, double preco, color cor, ENUM_LINE_STYLE estilo)
  {
   string n = "W20_" + nome;
   if(preco <= 0)
     {
      ObjectDelete(0, n);
      return;
     }
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_HLINE, 0, 0, preco);
   ObjectSetDouble(0, n, OBJPROP_PRICE, preco);
   ObjectSetInteger(0, n, OBJPROP_COLOR, cor);
   ObjectSetInteger(0, n, OBJPROP_STYLE, estilo);
   ObjectSetString(0, n, OBJPROP_TEXT, nome);
  }

void Desenhar()
  {
   if(!InpDesenharNiveis)
      return;
   ObjectsDeleteAll(0, "W20_NAKED");
   Linha("VAH", g_prev.vah, clrTomato, STYLE_SOLID);
   Linha("VAL", g_prev.val, clrDodgerBlue, STYLE_SOLID);
   Linha("VPOC", g_prev.poc, clrGold, STYLE_SOLID);
   Linha("VWAP", g_vwap, clrMediumOrchid, STYLE_DASH);
   for(int i = 0; i < ArraySize(g_naked); i++)
      Linha("NAKED" + IntegerToString(i), g_naked[i], clrGray, STYLE_DOT);
  }

//+------------------------------------------------------------------+
//| Lógica de cada barra fechada                                      |
//+------------------------------------------------------------------+
void NovaBarra()
  {
   AtualizarSessao();
   Desenhar();

   // validade da ordem stop
   if(TemOrdem())
     {
      g_ordemBarras++;
      if(g_ordemBarras >= InpValidadeOrdem)
        {
         trade.OrderDelete(g_ordem);
         g_ordem = 0;
        }
      return;
     }
   g_ordem = 0;

   if(TemPosicao() || !g_prev.ok)
      return;

   int agora = MinutosAgora();
   if(agora < Minutos(InpInicio) || agora >= Minutos(InpFimEntradas))
      return;

   int entradas;
   double resultado;
   ResumoDia(entradas, resultado);
   if(entradas >= InpMaxOperacoesDia)
      return;
   if(InpPerdaMaxDia > 0 && resultado <= -InpPerdaMaxDia)
      return;

   int precisa = InpMediaN + InpBarrasArmado + 2;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTFGatilho, 1, precisa, r) < precisa)
      return;

   datetime hoje = InicioDoDia(TimeCurrent());
   int nHoje = 0;
   while(nHoje < precisa && r[nHoje].time >= hoje)
      nHoje++;
   if(nHoje == 0)
      return;

   // o regime usa todas as barras fechadas de hoje
   MqlRates rd[];
   ArraySetAsSeries(rd, true);
   int nDia = CopyRates(_Symbol, InpTFGatilho, hoje, iTime(_Symbol, InpTFGatilho, 1), rd);
   if(nDia <= 0)
      return;
   ENUM_REGIME reg = Regime(rd, nDia);

   double ext;
   if(reg == REG_DENTRO && InpOperarRange)
     {
      // princípio de faixa / reversão: compra na VAL, venda na VAH
      if(Setup(r, nHoje, g_prev.val, +1, ext)) { Entrar(r, +1, g_prev.val, ext, "Range VAL"); return; }
      if(Setup(r, nHoje, g_prev.vah, -1, ext)) { Entrar(r, -1, g_prev.vah, ext, "Range VAH"); return; }
     }
   if(reg == REG_ACIMA)
     {
      // princípio de continuação: teste da VAH por cima; recuo na VWAP
      if(InpOperarContinuacao && Setup(r, nHoje, g_prev.vah, +1, ext)) { Entrar(r, +1, g_prev.vah, ext, "Continuação VAH"); return; }
      if(InpOperarVWAP && g_vwap > g_prev.vah && Setup(r, nHoje, g_vwap, +1, ext)) { Entrar(r, +1, g_vwap, ext, "Tendência VWAP"); return; }
     }
   if(reg == REG_ABAIXO)
     {
      if(InpOperarContinuacao && Setup(r, nHoje, g_prev.val, -1, ext)) { Entrar(r, -1, g_prev.val, ext, "Continuação VAL"); return; }
      if(InpOperarVWAP && g_vwap > 0 && g_vwap < g_prev.val && Setup(r, nHoje, g_vwap, -1, ext)) { Entrar(r, -1, g_vwap, ext, "Tendência VWAP"); return; }
     }
  }

//+------------------------------------------------------------------+
//| Gestão da posição a cada tick (barato: só compara preços)         |
//+------------------------------------------------------------------+
void GerirPosicao()
  {
   if(!TemPosicao())
      return;
   // posição aberta: cancela qualquer ordem pendente que tenha sobrado
   if(TemOrdem())
     {
      trade.OrderDelete(g_ordem);
      g_ordem = 0;
     }
   if(!InpParcial || g_parcialFeita || g_alvo1 <= 0)
      return;

   double preco = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(g_dir * (preco - g_alvo1) < 0)
      return;

   ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   double vol    = PositionGetDouble(POSITION_VOLUME);
   double passo  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double parc   = MathFloor(vol * InpParcialPct / 100.0 / passo) * passo;
   if(parc >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) && parc < vol)
      trade.PositionClosePartial(ticket, parc);

   // primeiro nível operacional atingido: protege no zero a zero
   MudarStop(Arred(g_entrada));
   g_parcialFeita = true;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime hoje = InicioDoDia(TimeCurrent());
   if(hoje != g_dia)
     {
      g_dia = hoje;
      g_deltaDisponivel = true;
      g_avisoDelta = false;
      NovoDia();
     }

   if(MinutosAgora() >= Minutos(InpZerar))
     {
      Zerar();
      return;
     }

   GerirPosicao();

   datetime barra = iTime(_Symbol, InpTFGatilho, 0);
   if(barra != g_ultimaBarra)
     {
      g_ultimaBarra = barra;
      NovaBarra();
     }
  }
//+------------------------------------------------------------------+
