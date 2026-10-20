//+------------------------------------------------------------------+
//|                                             Wizard3_Fita_WIN.mq5 |
//|                                                                  |
//|  Os 3 indicadores decidem apenas a DIRECAO PERMITIDA.            |
//|  Quem dispara a entrada e a FITA (Times & Trades).               |
//|                                                                  |
//|  CONTEXTO (na barra fechada, uma vez por barra)                  |
//|    AMA    : preco acima da media e media subindo    -> +1        |
//|    MACD   : linha acima da sinal e linha subindo    -> +1        |
//|    Stoch  : %K acima de %D e ainda nao esticado     -> +1        |
//|    Media dos tres votos, de -100 a +100. Acima de ForcaMin       |
//|    libera compra, abaixo de -ForcaMin libera venda. Um voto      |
//|    sozinho nunca libera nada, porque o zero dos outros dois      |
//|    continua dividindo por tres.                                  |
//|                                                                  |
//|  GATILHO (na fita, a cada segundo)                               |
//|    Agressao na janela de AgrJanelaSeg segundos que cumpre as      |
//|    tres condicoes ao mesmo tempo:                                |
//|      1. volume da janela >= AgrFator x volume normal da janela   |
//|      2. AgrDominioPct% do volume agredido de um mesmo lado        |
//|      3. preco deslocado >= AgrNiveis ticks do inicio da janela   |
//|    A condicao 3 e o que separa varrida de absorcao.              |
//|    A agressao precisa apontar para o MESMO lado do contexto.     |
//|                                                                  |
//|  ENTRADA                                                         |
//|    Modo 0: a mercado, no momento da agressao.                    |
//|    Modo 1 (padrao): limitada, valida por ValidadeBarras barras    |
//|    do grafico, como nos outros robos. O preco e sempre            |
//|      ancora - OffsetLimite  numa COMPRA                           |
//|      ancora + OffsetLimite  numa VENDA                            |
//|    e a ancora vem de AncoraLimite:                                |
//|      0 = preco atual                                              |
//|      1 = INICIO DA AGRESSAO, achado pela varredura em fatias de   |
//|          InpFatiaMs de tras para frente, que e o padrao. Nao e o  |
//|          primeiro negocio da janela, e o ponto onde o fluxo       |
//|          realmente comecou                                        |
//|      2 = base do movimento, o menor preco negociado na janela     |
//|          numa compra e o maior numa venda                         |
//|    AncoraMinPts descarta a ordem que nascer perto demais do       |
//|    preco atual, que na pratica seria uma ordem a mercado.         |
//|                                                                  |
//|  PROTECAO                                                        |
//|    Stop e alvo vao na bolsa junto com a ordem.                   |
//|    Trailing proprio, a cada tick, so no stop.                    |
//|    Fluxo contra cancela a limitada pendente, nunca fecha         |
//|    posicao aberta. O cancelamento tem limiares PROPRIOS, mais     |
//|    exigentes que os da entrada, porque cancelar destroi uma       |
//|    oportunidade. Com CancNiveis em 0 ele julga so pelo volume e   |
//|    pelo dominio, sem exigir deslocamento: quando a limitada esta  |
//|    longe, o preco executa a ordem antes de conseguir deslocar.    |
//|                                                                  |
//|  Conta netting (B3): uma posicao por simbolo.                    |
//|                                                                  |
//|  PERFIL DOS NUMEROS                                              |
//|    O gatilho nasce um pouco agressivo: fator 2.0, dominio 70% e  |
//|    10 ticks de deslocamento. Para apertar, suba o fator e os      |
//|    niveis. O cancelamento por agressao contra fica em 15 ticks,   |
//|    de proposito mais exigente que a entrada, para nao desistir    |
//|    da ordem no primeiro repique.                                 |
//|    A forca minima do contexto fica em 50: abaixo disso um         |
//|    indicador sozinho passaria a abrir ordem, e ai o consenso      |
//|    dos tres deixa de existir.                                     |
//|                                                                  |
//|  v1.00 - primeira versao                                         |
//+------------------------------------------------------------------+
#property copyright "maikon arruda"
#property version   "1.00"
#property description "3 indicadores como contexto, entrada disparada pela fita (Times & Trades)"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "Geral"
input ulong           InpMagic         = 777002;     // Numero magico (unico por robo)
input double          InpLotes         = 1.0;        // Contratos por entrada
input ENUM_TIMEFRAMES InpTF            = PERIOD_M1;  // Tempo grafico do contexto

input group "Contexto: consenso dos 3 indicadores"
input double InpForcaMin       = 50;        // Media minima para liberar o lado [0...100]
input int    InpAMAPeriodo     = 10;        // AMA: periodo de media
input int    InpAMAFast        = 2;         // AMA: EMA rapida
input int    InpAMASlow        = 30;        // AMA: EMA lenta
input int    InpMACDFast       = 12;        // MACD: EMA rapida
input int    InpMACDSlow       = 24;        // MACD: EMA lenta
input int    InpMACDSignal     = 9;         // MACD: media da diferenca
input int    InpStochK         = 8;         // Stoch: periodo K
input int    InpStochD         = 3;         // Stoch: periodo D
input int    InpStochSlow      = 3;         // Stoch: suavizacao
input double InpStochTeto      = 80;        // Stoch: acima disso nao vota compra
input double InpStochPiso      = 20;        // Stoch: abaixo disso nao vota venda

input group "Gatilho: agressao na fita"
input int    InpAgrJanelaSeg   = 10;        // Janela de leitura (segundos)
input double InpAgrFator       = 2.0;       // Volume da janela >= fator x volume normal
input double InpAgrDominioPct  = 70;        // % do volume agredido de um lado
input int    InpAgrNiveis      = 10;        // Niveis (ticks) que o preco andou a favor
input int    InpAgrMediaN      = 30;        // Barras M1 para medir o volume normal
input long   InpLoteTeto       = 1000;      // Negocio acima disso e leilao/cruzada: descartado (0 = sem teto)

input group "Entrada"
input int    InpModoEntrada    = 1;         // 0 = a mercado | 1 = limitada
input int    InpAncoraLimite   = 1;         // 0 = preco atual | 1 = inicio da agressao | 2 = base do movimento
input int    InpOffsetLimite   = 250;       // Pontos a partir da ancora (compra abaixo, venda acima)
input int    InpFatiaMs        = 1000;      // [ancora 1] tamanho da fatia da varredura (ms)
input double InpTolRajada      = 0.30;      // [ancora 1] quanto uma fatia pode remar contra (0.30 = 30%)
input int    InpAncoraMinPts   = 25;        // Distancia minima do preco atual (abaixo disso nao manda)
input int    InpValidadeBarras = 3;         // [modo 1] validade da limitada (barras)

input group "Stop e alvo"
input int    InpStopPoints     = 125;       // Stop (pontos)
input int    InpTakePoints     = 250;       // Alvo (pontos)

input group "Trailing stop (proprio, a cada tick)"
input bool   InpUsarTrailing   = true;      // Ligar trailing
input int    InpTrailAtivar    = 75;        // Ativa depois de X pontos a favor
input int    InpTrailDist      = 75;        // Distancia do stop ao preco (pontos)

input group "Cancelar a limitada por agressao contra"
input bool   InpCancUsar       = true;      // Ligar a regra
input double InpCancFator      = 2.5;       // Volume da janela >= fator x volume normal
input double InpCancDominio    = 80;        // % do volume agredido CONTRA a ordem
input int    InpCancNiveis     = 0;         // Niveis (ticks) contra a ordem (0 = ignora o deslocamento)

input group "Horario (hora do servidor)"
input string InpInicio         = "09:15";   // Inicio das entradas
input string InpFimEntradas    = "17:15";   // Fim das entradas
input string InpZerar          = "17:50";   // Hora de zerar tudo

input group "Limites do dia"
input int    InpMaxOperacoes   = 6;         // Maximo de entradas por dia (0 = sem limite)
input double InpPerdaMaxDia    = 300;       // Perda maxima do dia em R$ (0 = sem limite)
input int    InpPerdasSeguidas = 3;         // Para no dia apos N perdas seguidas (0 = nao)

input group "Painel"
input bool   InpPainel         = true;      // Mostrar painel no grafico
input int    InpPainelX        = 12;        // Posicao X (pixels)
input int    InpPainelY        = 24;        // Posicao Y (pixels)

//+------------------------------------------------------------------+
//| Globais                                                          |
//+------------------------------------------------------------------+
CTrade   trade;

int      hAMA   = INVALID_HANDLE;
int      hMACD  = INVALID_HANDLE;
int      hStoch = INVALID_HANDLE;

int      gIni = 0, gFim = 0, gZerar = 0;   // horarios em minutos do dia
datetime gDiaRef   = 0;
bool     gBloqDia  = false;
datetime gUltApura = 0;
datetime gUltBarra = 0;

int      gContexto = 0;                    // -1 venda | 0 nada | +1 compra
double   gScore    = 0;                    // media dos votos, -100 a +100
int      gVotos[3];                        // AMA, MACD, Stoch

datetime gUltAgr   = 0;                    // ultima leitura da fita
int      gAgrDir   = 0;                    // lado da agressao atual
double   gAgrFator = 0;                    // fator de volume da janela
double   gFitaFator = 0;                   // volume da janela / volume normal
double   gFitaDomC  = 0;                   // % do volume agredido na compra
double   gFitaDomV  = 0;                   // % do volume agredido na venda
double   gFitaSubiu = 0;                   // ticks que o preco subiu na janela
double   gFitaCaiu  = 0;                   // ticks que o preco caiu na janela
double   gAgrIni   = 0;                    // preco do primeiro negocio da janela
double   gAgrMax   = 0;                    // maior preco negociado na janela
double   gAgrMin   = 0;                    // menor preco negociado na janela

double   gUltPreco = 0;                    // preco da ultima limitada enviada
string   gPre = "W3F_";                    // prefixo dos objetos do painel

//+------------------------------------------------------------------+
//| Utilidades                                                       |
//+------------------------------------------------------------------+
double TickSz()
  {
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return((t > 0.0) ? t : _Point);
  }

double ArredTick(const double p)
  {
   double tk = TickSz();
   if(tk <= 0.0)
      return(NormalizeDouble(p, _Digits));
   return(NormalizeDouble(MathRound(p / tk) * tk, _Digits));
  }

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

bool PosicaoAberta()
  {
   if(!PositionSelect(_Symbol))
      return(false);
   return((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

//--- devolve o ticket e o lado (+1 compra, -1 venda) da pendente
bool Pendente(ulong &ticket, int &dir)
  {
   ticket = 0;
   dir    = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      long tipo = OrderGetInteger(ORDER_TYPE);
      if(tipo == ORDER_TYPE_BUY_LIMIT || tipo == ORDER_TYPE_BUY_STOP)
         dir = 1;
      else
         if(tipo == ORDER_TYPE_SELL_LIMIT || tipo == ORDER_TYPE_SELL_STOP)
            dir = -1;
      ticket = t;
      return(true);
     }
   return(false);
  }

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
      trade.OrderDelete(t);
     }
  }

void FecharPosicao()
  {
   if(!PosicaoAberta())
      return;
   trade.PositionClose(_Symbol);
  }

bool NovaBarra()
  {
   datetime t = iTime(_Symbol, InpTF, 0);
   if(t == 0 || t == gUltBarra)
      return(false);
   gUltBarra = t;
   return(true);
  }

//+------------------------------------------------------------------+
//| CONTEXTO: os 3 indicadores na barra fechada                      |
//+------------------------------------------------------------------+
int Contexto()
  {
   double ama[], macd[], sig[], kk[], dd[];
   ArraySetAsSeries(ama,  true);
   ArraySetAsSeries(macd, true);
   ArraySetAsSeries(sig,  true);
   ArraySetAsSeries(kk,   true);
   ArraySetAsSeries(dd,   true);

   if(CopyBuffer(hAMA,   0, 1, 2, ama)  < 2)
      return(gContexto);
   if(CopyBuffer(hMACD,  0, 1, 2, macd) < 2)
      return(gContexto);
   if(CopyBuffer(hMACD,  1, 1, 2, sig)  < 2)
      return(gContexto);
   if(CopyBuffer(hStoch, 0, 1, 1, kk)   < 1)
      return(gContexto);
   if(CopyBuffer(hStoch, 1, 1, 1, dd)   < 1)
      return(gContexto);

   double close1 = iClose(_Symbol, InpTF, 1);
   if(close1 <= 0.0)
      return(gContexto);

   //--- voto da AMA: preco do lado certo da media E media inclinada
   int vAMA = 0;
   if(close1 > ama[0] && ama[0] > ama[1])
      vAMA = 1;
   else
      if(close1 < ama[0] && ama[0] < ama[1])
         vAMA = -1;

   //--- voto do MACD: linha do lado certo da sinal E linha andando
   int vMACD = 0;
   if(macd[0] > sig[0] && macd[0] > macd[1])
      vMACD = 1;
   else
      if(macd[0] < sig[0] && macd[0] < macd[1])
         vMACD = -1;

   //--- voto do Stoch: cruzamento com espaco para andar
   int vStoch = 0;
   if(kk[0] > dd[0] && kk[0] < InpStochTeto)
      vStoch = 1;
   else
      if(kk[0] < dd[0] && kk[0] > InpStochPiso)
         vStoch = -1;

   gVotos[0] = vAMA;
   gVotos[1] = vMACD;
   gVotos[2] = vStoch;

   gScore = (vAMA + vMACD + vStoch) * 100.0 / 3.0;

   if(gScore >= InpForcaMin)
      return(1);
   if(gScore <= -InpForcaMin)
      return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| CLASSIFICACAO DO AGRESSOR                                        |
//|                                                                  |
//| Ponto unico onde se decide de que lado foi a agressao, igual ao   |
//| Fita_WIN, para que os dois robos nunca leiam a fita de formas     |
//| diferentes. Ordem de decisao:                                     |
//|   1. flag BUY ou SELL do feed, que e a informacao da bolsa       |
//|   2. preco negociado contra o book do proprio tick               |
//|      (bateu no ask = comprador agrediu; no bid = vendedor)       |
//|   3. uptick ou downtick contra o negocio anterior                |
//|                                                                  |
//| Devolve +1 compra, -1 venda, 0 realmente indefinido. O volume do  |
//| indefinido nao se perde: conta no total e so nao entra no delta,  |
//| porque inventar um lado seria pior que admitir que nao da para    |
//| saber.                                                            |
//+------------------------------------------------------------------+
int LadoAgressor(const MqlTick &t, double &ultPreco)
  {
   bool compra = ((t.flags & TICK_FLAG_BUY)  != 0);
   bool venda  = ((t.flags & TICK_FLAG_SELL) != 0);

   int lado = 0;

   if(compra != venda)
      lado = compra ? 1 : -1;
   else
      if(t.last > 0.0)
        {
         //--- sem flag util: compara com o book daquele instante
         if(t.ask > 0.0 && t.last >= t.ask)
            lado = 1;
         else
            if(t.bid > 0.0 && t.last <= t.bid)
               lado = -1;
            else
               //--- book indisponivel: regra do uptick
               if(ultPreco > 0.0 && t.last > ultPreco)
                  lado = 1;
               else
                  if(ultPreco > 0.0 && t.last < ultPreco)
                     lado = -1;
        }

   if(t.last > 0.0)
      ultPreco = t.last;
   return(lado);
  }

//+------------------------------------------------------------------+
//| Volume normal esperado na janela                                 |
//+------------------------------------------------------------------+
double VolNormalJanela()
  {
   double soma = 0.0;
   int    n    = 0;
   long   v[];
   for(int i = 1; i <= InpAgrMediaN; i++)
     {
      if(CopyRealVolume(_Symbol, PERIOD_M1, i, 1, v) == 1 && v[0] > 0)
        {
         soma += (double)v[0];
         n++;
        }
     }
   if(n == 0)
      return(0.0);
   return((soma / n) * ((double)InpAgrJanelaSeg / 60.0));
  }

//+------------------------------------------------------------------+
//| GATILHO: le a fita da janela e devolve o lado da agressao        |
//|  dir = +1 agressao compradora que varreu para cima               |
//|  dir = -1 agressao vendedora que varreu para baixo               |
//|  Preenche tambem contraNiveis: quanto o preco andou para cada    |
//|  lado, para a regra de cancelamento.                             |
//+------------------------------------------------------------------+
bool LerFita(int &dir, double &fator, double &subiu, double &caiu)
  {
   dir   = 0;
   fator = 0.0;
   subiu = 0.0;
   caiu  = 0.0;

   datetime fim = TimeCurrent();
   datetime ini = fim - InpAgrJanelaSeg;
   if(ini <= 0)
      return(false);

   MqlTick t[];
   int n = CopyTicksRange(_Symbol, t, COPY_TICKS_TRADE, (ulong)ini * 1000, (ulong)fim * 1000);
   if(n <= 0)
      return(false);

   double volC = 0.0, volV = 0.0, volN = 0.0;
   double pIni = 0.0, pMax = 0.0, pMin = 0.0, ultimo = 0.0;

   for(int i = 0; i < n; i++)
     {
      double p = t[i].last;
      if(p <= 0.0)
         continue;

      double vol = (t[i].volume_real > 0.0) ? t[i].volume_real : (double)t[i].volume;
      if(vol <= 0.0)
         vol = 1.0;

      //--- negocio absurdo: leilao de abertura ou cruzada de balcao
      if(InpLoteTeto > 0 && vol > (double)InpLoteTeto)
         continue;

      if(pIni == 0.0)
        {
         pIni = p;
         pMax = p;
         pMin = p;
        }
      if(p > pMax)
         pMax = p;
      if(p < pMin)
         pMin = p;

      int lado = LadoAgressor(t[i], ultimo);
      if(lado > 0)
         volC += vol;
      else
         if(lado < 0)
            volV += vol;
         else
            volN += vol;   // volume preservado, sem lado atribuido
     }

   if(pIni <= 0.0)
      return(false);

   //--- publica os precos da janela, usados para ancorar a limitada
   gAgrIni = pIni;
   gAgrMax = pMax;
   gAgrMin = pMin;

   double tk = TickSz();
   if(tk > 0.0)
     {
      subiu = (pMax - pIni) / tk;
      caiu  = (pIni - pMin) / tk;
     }

   //--- o neutro entra no divisor: se metade da fita veio sem agressor
   //--- identificavel, nao se pode afirmar que ha dominio de um lado
   double total = volC + volV + volN;
   if(total <= 0.0)
      return(false);

   double normal = VolNormalJanela();
   if(normal <= 0.0)
      return(false);

   fator = total / normal;

   //--- publica a leitura crua. O cancelamento usa estes numeros com os
   //--- seus proprios limiares, e nao os da entrada.
   gFitaFator = fator;
   gFitaDomC  = volC / total * 100.0;
   gFitaDomV  = volV / total * 100.0;
   gFitaSubiu = subiu;
   gFitaCaiu  = caiu;

   if(fator < InpAgrFator)
      return(false);

   if(volC >= volV)
     {
      if(volC / total * 100.0 < InpAgrDominioPct)
         return(false);
      if(subiu < (double)InpAgrNiveis)
         return(false);
      dir = 1;
     }
   else
     {
      if(volV / total * 100.0 < InpAgrDominioPct)
         return(false);
      if(caiu < (double)InpAgrNiveis)
         return(false);
      dir = -1;
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| INICIO DA RAJADA                                                 |
//|                                                                  |
//| Varre a janela de TRAS PARA FRENTE em fatias de InpFatiaMs e      |
//| acumula o delta de cada uma. Enquanto a fatia concorda com a      |
//| direcao do sinal, ou e neutra, ela faz parte da rajada. Na        |
//| primeira fatia que rema contra com forca, a varredura para: a     |
//| rajada comecou depois dela.                                       |
//|                                                                  |
//| Isso resolve o problema da janela deslizante: o primeiro negocio  |
//| da janela de 10 segundos e so o preco de 10 segundos atras, que   |
//| nao e o instante em que o fluxo comecou. Aqui o inicio e achado   |
//| pelo proprio fluxo.                                               |
//|                                                                  |
//| Devolve o preco do primeiro negocio da rajada, ou 0 se nao achar. |
//+------------------------------------------------------------------+
double InicioRajada(const int direcao)
  {
   if(direcao == 0)
      return(0.0);

   ulong fimMs = (ulong)TimeCurrent() * 1000 + 999;
   ulong iniMs = (fimMs > (ulong)InpAgrJanelaSeg * 1000) ? fimMs - (ulong)InpAgrJanelaSeg * 1000 : 0;

   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, iniMs, fimMs);
   if(n <= 0)
      return(0.0);

   int    idx         = n - 1;     // comeca no negocio mais recente
   double precoRajada = 0.0;
   int    fatias      = 0;

   while(idx >= 0)
     {
      //--- limites da fatia que termina em ticks[idx]
      ulong fimFatia = ticks[idx].time_msc;
      ulong iniFatia = (fimFatia > (ulong)InpFatiaMs) ? fimFatia - (ulong)InpFatiaMs : 0;

      double delta = 0.0, vol = 0.0;
      int    j = idx;
      while(j >= 0 && ticks[j].time_msc >= iniFatia)
        {
         double q = (ticks[j].volume_real > 0.0) ? ticks[j].volume_real : (double)ticks[j].volume;
         if(q > 0.0 && !(InpLoteTeto > 0 && q > (double)InpLoteTeto))
           {
            //--- a varredura e de tras para frente, entao a regra do
            //--- uptick nao se aplica: usa so a flag e o book
            double semRef = 0.0;
            int    lado   = LadoAgressor(ticks[j], semRef);
            delta += lado * q;
            vol   += q;          // volume neutro dilui a fatia, nao desaparece
           }
         j--;
        }

      //--- fatia remando contra a direcao: a rajada comeca depois dela
      if(vol > 0.0)
        {
         double saldo = delta / vol;
         if(saldo * direcao < -InpTolRajada)
            break;
        }

      //--- fatia faz parte da rajada: guarda o preco do primeiro negocio dela
      int primeiro = j + 1;
      if(primeiro >= 0 && primeiro < n && ticks[primeiro].last > 0.0)
         precoRajada = ticks[primeiro].last;

      fatias++;
      idx = j;
     }

   if(precoRajada > 0.0)
      PrintFormat("Rajada: %d fatia(s) de %dms | comecou em %s",
                  fatias, InpFatiaMs, DoubleToString(precoRajada, _Digits));

   return(precoRajada);
  }

//+------------------------------------------------------------------+
//| Entrada                                                          |
//+------------------------------------------------------------------+
bool EnviarEntrada(const int dir)
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return(false);

   double sl, tp, preco;

   if(InpModoEntrada == 0)
     {
      //--- a mercado
      if(dir > 0)
        {
         sl = ArredTick(t.ask - InpStopPoints * _Point);
         tp = ArredTick(t.ask + InpTakePoints * _Point);
         return(trade.Buy(InpLotes, _Symbol, 0.0, sl, tp, "W3F agressao"));
        }
      sl = ArredTick(t.bid + InpStopPoints * _Point);
      tp = ArredTick(t.bid - InpTakePoints * _Point);
      return(trade.Sell(InpLotes, _Symbol, 0.0, sl, tp, "W3F agressao"));
     }

   //--- limitada: de onde medir o preco
   double ancora = 0.0;
   if(InpAncoraLimite == 1)
     {
      //--- acha o inicio real do fluxo varrendo as fatias de tras para frente
      ancora = InicioRajada(dir);
      if(ancora <= 0.0)
        {
         ancora = gAgrIni;   // reserva: primeiro negocio da janela
         Print("Nao identifiquei o inicio da rajada - usando o primeiro negocio da janela");
        }
     }
   else
      if(InpAncoraLimite == 2)
         ancora = (dir > 0) ? gAgrMin : gAgrMax;

   if(InpAncoraLimite == 0 || ancora <= 0.0)
      ancora = t.last;

   if(dir > 0)
     {
      //--- compra: tantos pontos ABAIXO da ancora
      preco = ArredTick(ancora - InpOffsetLimite * _Point);

      //--- compra limitada tem que ficar abaixo do preco, e longe o
      //--- suficiente para nao ser uma ordem a mercado disfarcada
      if(preco >= t.ask)
         return(false);
      if((t.ask - preco) < InpAncoraMinPts * _Point)
         return(false);

      sl = ArredTick(preco - InpStopPoints * _Point);
      tp = ArredTick(preco + InpTakePoints * _Point);
      gUltPreco = preco;
      return(trade.BuyLimit(InpLotes, preco, _Symbol, sl, tp, ORDER_TIME_DAY, 0, "W3F agressao"));
     }

   //--- venda: tantos pontos ACIMA da ancora
   preco = ArredTick(ancora + InpOffsetLimite * _Point);

   //--- venda limitada tem que ficar acima do preco
   if(preco <= t.bid)
      return(false);
   if((preco - t.bid) < InpAncoraMinPts * _Point)
      return(false);

   sl = ArredTick(preco + InpStopPoints * _Point);
   tp = ArredTick(preco - InpTakePoints * _Point);
   gUltPreco = preco;
   return(trade.SellLimit(InpLotes, preco, _Symbol, sl, tp, ORDER_TIME_DAY, 0, "W3F agressao"));
  }

//+------------------------------------------------------------------+
//| Cancela a limitada vencida pelas barras de validade              |
//+------------------------------------------------------------------+
void CancelarVencida()
  {
   if(InpModoEntrada == 0 || InpValidadeBarras <= 0)
      return;
   ulong ticket;
   int   dir;
   if(!Pendente(ticket, dir))
      return;

   datetime posta = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
   if(posta <= 0)
      return;

   //--- quantas barras do grafico se passaram desde o envio
   int barras = iBarShift(_Symbol, InpTF, posta, false);
   if(barras >= InpValidadeBarras)
     {
      if(trade.OrderDelete(ticket))
         PrintFormat("Limitada cancelada: venceram as %d barras de validade", InpValidadeBarras);
     }
  }

//+------------------------------------------------------------------+
//| Cancela a limitada quando a agressao vem contra                  |
//|  Nunca mexe em posicao aberta.                                   |
//+------------------------------------------------------------------+
void CancelarPorAgressao()
  {
   if(!InpCancUsar)
      return;

   ulong ticket;
   int   dir;
   if(!Pendente(ticket, dir))
      return;
   if(dir == 0)
      return;

   //--- volume da janela, pelo limiar do cancelamento
   if(gFitaFator < InpCancFator)
      return;

   //--- dominio do lado CONTRA a ordem
   double dom = (dir > 0) ? gFitaDomV : gFitaDomC;
   if(dom < InpCancDominio)
      return;

   //--- deslocamento contra a ordem, somente quando exigido.
   //--- Com a limitada longe (offset grande), o preco nao consegue
   //--- deslocar o bastante antes de executar, e exigir deslocamento
   //--- aqui desliga a regra na pratica. Por isso o 0 existe.
   double contra = (dir > 0) ? gFitaCaiu : gFitaSubiu;
   if(InpCancNiveis > 0 && contra < (double)InpCancNiveis)
      return;

   if(trade.OrderDelete(ticket))
      PrintFormat("Limitada de %s cancelada: fluxo contra de %.1fx com %.0f%% de dominio, %.0f niveis",
                  (dir > 0) ? "compra" : "venda", gFitaFator, dom, contra);
  }

//+------------------------------------------------------------------+
//| Apuracao do dia                                                  |
//+------------------------------------------------------------------+
void ApurarDia()
  {
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
//| Trailing proprio, a cada tick, so no stop                        |
//+------------------------------------------------------------------+
void Trailing()
  {
   if(!InpUsarTrailing)
      return;
   if(!PosicaoAberta())
      return;

   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;

   long   tipo    = PositionGetInteger(POSITION_TYPE);
   double entrada = PositionGetDouble(POSITION_PRICE_OPEN);
   double slAtual = PositionGetDouble(POSITION_SL);
   double tpAtual = PositionGetDouble(POSITION_TP);
   double tk      = TickSz();

   if(tipo == POSITION_TYPE_BUY)
     {
      if((t.bid - entrada) < InpTrailAtivar * _Point)
         return;
      double novo = ArredTick(t.bid - InpTrailDist * _Point);
      if(novo < t.bid && (slAtual <= 0.0 || novo > slAtual + tk * 0.5))
         trade.PositionModify(_Symbol, novo, tpAtual);
      return;
     }

   if(tipo == POSITION_TYPE_SELL)
     {
      if((entrada - t.ask) < InpTrailAtivar * _Point)
         return;
      double novo = ArredTick(t.ask + InpTrailDist * _Point);
      if(novo > t.ask && (slAtual <= 0.0 || novo < slAtual - tk * 0.5))
         trade.PositionModify(_Symbol, novo, tpAtual);
     }
  }

//+------------------------------------------------------------------+
//| Painel                                                           |
//+------------------------------------------------------------------+
void Linha(const int idx, const string texto, const color cor)
  {
   string nome = gPre + IntegerToString(idx);
   if(ObjectFind(0, nome) < 0)
     {
      ObjectCreate(0, nome, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nome, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nome, OBJPROP_XDISTANCE, InpPainelX);
      ObjectSetInteger(0, nome, OBJPROP_YDISTANCE, InpPainelY + idx * 16);
      ObjectSetInteger(0, nome, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, nome, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nome, OBJPROP_SELECTABLE, false);
     }
   ObjectSetString(0, nome, OBJPROP_TEXT, texto);
   ObjectSetInteger(0, nome, OBJPROP_COLOR, cor);
  }

string NomeVoto(const int v)
  {
   if(v > 0)
      return("compra");
   if(v < 0)
      return("venda ");
   return("neutro");
  }

void Painel()
  {
   if(!InpPainel)
      return;

   color cCtx = (gContexto > 0) ? clrMediumSeaGreen : ((gContexto < 0) ? clrIndianRed : clrSilver);

   Linha(0, "Wizard3 + Fita", clrSilver);
   Linha(1, StringFormat("contexto   %+.0f  (%s)", gScore,
                         (gContexto > 0) ? "compra liberada" :
                         ((gContexto < 0) ? "venda liberada" : "nada liberado")), cCtx);
   Linha(2, StringFormat("AMA %s   MACD %s   Stoch %s",
                         NomeVoto(gVotos[0]), NomeVoto(gVotos[1]), NomeVoto(gVotos[2])), clrSilver);
   Linha(3, StringFormat("fita       %.1fx  (dispara em %.1fx)", gAgrFator, InpAgrFator),
         (gAgrFator >= InpAgrFator) ? clrGold : clrSilver);
   Linha(4, StringFormat("agressao   %s   (dom C %.0f%%  V %.0f%%)",
                         NomeVoto(gAgrDir), gFitaDomC, gFitaDomV),
         (gAgrDir > 0) ? clrMediumSeaGreen : ((gAgrDir < 0) ? clrIndianRed : clrSilver));
   Linha(5, gBloqDia ? "dia BLOQUEADO por limite" : "dia liberado",
         gBloqDia ? clrIndianRed : clrSilver);
  }

void LimparPainel()
  {
   ObjectsDeleteAll(0, gPre);
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
      Print("Horario invalido, use o formato HH:MM");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpModoEntrada < 0 || InpModoEntrada > 1)
     {
      Print("InpModoEntrada aceita apenas 0 ou 1");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpAncoraLimite < 0 || InpAncoraLimite > 2)
     {
      Print("InpAncoraLimite aceita apenas 0, 1 ou 2");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpOffsetLimite < 0)
     {
      Print("InpOffsetLimite nao pode ser negativo");
      return(INIT_PARAMETERS_INCORRECT);
     }

   hAMA   = iAMA(_Symbol, InpTF, InpAMAPeriodo, InpAMAFast, InpAMASlow, 0, PRICE_CLOSE);
   hMACD  = iMACD(_Symbol, InpTF, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);
   hStoch = iStochastic(_Symbol, InpTF, InpStochK, InpStochD, InpStochSlow, MODE_SMA, STO_LOWHIGH);

   if(hAMA == INVALID_HANDLE || hMACD == INVALID_HANDLE || hStoch == INVALID_HANDLE)
     {
      Print("Erro ao criar os indicadores do contexto");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   gVotos[0] = 0;
   gVotos[1] = 0;
   gVotos[2] = 0;

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hAMA   != INVALID_HANDLE)
      IndicatorRelease(hAMA);
   if(hMACD  != INVALID_HANDLE)
      IndicatorRelease(hMACD);
   if(hStoch != INVALID_HANDLE)
      IndicatorRelease(hStoch);
   LimparPainel();
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int agora = dt.hour * 60 + dt.min;

   //--- virada de dia
   datetime hoje = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(hoje != gDiaRef)
     {
      gDiaRef   = hoje;
      gBloqDia  = false;
      gUltApura = 0;
     }

   ApurarDia();

   //--- hora de zerar
   if(agora >= gZerar)
     {
      CancelarPendentes();
      FecharPosicao();
      Painel();
      return;
     }

   //--- administra o que ja esta na mao, em qualquer horario
   Trailing();
   CancelarVencida();

   //--- contexto: uma vez por barra
   if(NovaBarra())
      gContexto = Contexto();

   //--- fita: uma vez por segundo
   double subiu = 0.0, caiu = 0.0;
   if(TimeCurrent() != gUltAgr)
     {
      gUltAgr = TimeCurrent();
      int    d = 0;
      double f = 0.0;
      if(!LerFita(d, f, subiu, caiu))
         d = 0;
      gAgrDir   = d;
      gAgrFator = f;

      CancelarPorAgressao();
     }

   Painel();

   //--- entradas
   bool podeEntrar = (!gBloqDia) && (agora >= gIni) && (agora < gFim);
   if(!podeEntrar)
     {
      CancelarPendentes();
      return;
     }

   if(gContexto == 0)
      return;
   if(gAgrDir != gContexto)
      return;
   if(PosicaoAberta())
      return;

   ulong ticket;
   int   dirPend;
   if(Pendente(ticket, dirPend))
      return;

   if(EnviarEntrada(gContexto))
      PrintFormat("Entrada %s: contexto %+.0f, agressao %.1fx, janela %s..%s, limitada em %s",
                  (gContexto > 0) ? "COMPRA" : "VENDA", gScore, gAgrFator,
                  DoubleToString(gAgrIni, _Digits),
                  DoubleToString((gContexto > 0) ? gAgrMax : gAgrMin, _Digits),
                  DoubleToString(gUltPreco, _Digits));
  }
//+------------------------------------------------------------------+
