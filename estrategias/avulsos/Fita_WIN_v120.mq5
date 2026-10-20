//+------------------------------------------------------------------+
//|                                                   Fita_WIN.mq5   |
//|                                                                   |
//|  LEITURA DE FITA (Times and Sales) para WIN na B3.                |
//|                                                                   |
//|  Le os negocios reais com COPY_TICKS_TRADE e analisa uma janela   |
//|  curta de segundos - nao de barras. Tres sinais independentes:    |
//|                                                                   |
//|   1. GRANDES LOTES  negocios individuais acima de um limiar.      |
//|                     Quem manda lote grande costuma saber algo.    |
//|                                                                   |
//|   2. VELOCIDADE     numero de negocios por segundo muito acima    |
//|                     da media. Fita acelerando = algo acontecendo. |
//|                                                                   |
//|   3. DESEQUILIBRIO  volume agredido na compra muito maior que na  |
//|                     venda, ou o contrario.                        |
//|                                                                   |
//|  Os tres apontam uma direcao (+1 compra, -1 venda, 0 nada) e o    |
//|  robo exige um numero minimo deles concordando.                   |
//|                                                                   |
//|  IMPORTANTE: no testador, use "cada tick com base em ticks reais".|
//|  Nos outros modos as flags de agressor nao existem.               |
//|                                                                   |
//|  v1.10 - janela base de velocidade passa a ser DESLIZANTE.        |
//|          Antes relia 600s de ticks a cada segundo; agora mantem   |
//|          a contagem por segundo num buffer circular e so soma o   |
//|          segundo que entrou, subtraindo o que saiu pela cauda.    |
//|          Tambem valida que a conta e hedging: com tres EAs no     |
//|          mesmo simbolo, netting faria um sobrescrever o SL/TP     |
//|          do outro.                                                |
//|                                                                   |
//|  v1.22 - FILTRO DE TENDENCIA REMOVIDO. A media do M15 com zona     |
//|          neutra barrava a maior parte das entradas no M1, e o       |
//|          contexto direcional passa a ser so o delta acumulado da    |
//|          sessao, que e leitura de fluxo e nao de grafico. Saiu      |
//|          tambem o InpSinaisIgnoraTend, que existia apenas para      |
//|          furar esse filtro.                                         |
//|                                                                     |
//|  v1.21 - a regra de cancelamento passa a usar LerFita, a mesma     |
//|          leitura dos tres sinais, em vez de uma classificacao      |
//|          propria que ignorava o LadoAgressor, o teto de lote e o   |
//|          volume neutro. O volume de referencia agora exige volume  |
//|          real: sem ele a regra nao opina, para nao comparar        |
//|          contratos com numero de negocios. Limiares do             |
//|          cancelamento ficam mais exigentes que os da entrada       |
//|          (2.5x e 80%) e o deslocamento vira opcional, porque com a |
//|          limitada a 250 pontos da ancora o preco executa a ordem   |
//|          antes de conseguir deslocar. Validade da ordem passa a    |
//|          ser em BARRAS do grafico. Entrada ancorada no inicio da   |
//|          rajada, offset 250, stop 120 e alvo 75.                   |
//|                                                                    |
//|  v1.20 - offset da limite padrao = 150 pontos.                    |
//|          MODO CAUTELOSO: quando o preco vai e volta (N reversoes  |
//|          de pelo menos X pontos na janela), o robo passa a exigir |
//|          mais sinais concordando. Nao bloqueia: so aperta a        |
//|          entrada. Fica ligado no minimo InpChopHoldMin minutos.   |
//+------------------------------------------------------------------+
#property copyright "Maikon"
#property version   "1.22"
#property strict

#include <Trade\Trade.mqh>

//--- Sinais ativos
input bool   InpUsarGrandes      = true;   // Sinal 1: grandes lotes
input bool   InpUsarVelocidade   = true;   // Sinal 2: velocidade da fita
input bool   InpUsarDesequilibrio= true;   // Sinal 3: desequilibrio de agressao
input int    InpMinSinais        = 2;      // Quantos sinais precisam concordar (1 a 3)

//--- Janelas de leitura
input int    InpJanelaSeg        = 15;     // Janela curta de analise (segundos)
input int    InpJanelaBaseSeg    = 600;    // Janela de referencia para as medias (segundos)
input bool   InpBootstrapBase    = true;   // Encher a janela base do historico na carga do EA

//--- Sinal 1: grandes lotes
input long   InpLoteGrande       = 50;     // Tamanho minimo para o negocio contar como grande
input long   InpLoteTeto         = 1000;   // Acima disso e leilao/cruzada: negocio descartado (0 = sem teto)
input long   InpVolGrandesMin    = 200;    // Volume liquido dos grandes exigido na janela

//--- Sinal 2: velocidade
input double InpFatorVelocidade  = 3.0;    // Negocios/seg exigidos acima da media (3.0 = o triplo)
input int    InpMinNegocios      = 20;     // Minimo de negocios na janela para o sinal valer

//--- Sinal 3: desequilibrio
input double InpDesequilibrioMin = 0.60;   // 0.60 = um lado com 80% do volume agredido
input long   InpVolMinJanela     = 300;    // Volume minimo na janela para o sinal valer

//--- Delta acumulado: validacao pelo saldo de agressao da sessao
enum EAncoraAcum
{
   ACUM_INICIO_DIA = 0,   // Desde a abertura do pregao (reconstroi do historico)
   ACUM_INICIO_EA  = 1    // Desde que o EA foi carregado
};

//--- MODO do acumulado. Ver o bloco DELTA ACUMULADO mais abaixo
//--- para por que o nivel absoluto nao funciona como filtro.
enum EModoAcum
{
   ACUM_NIVEL    = 0,   // Saldo total desde a ancora (trava num lado so)
   ACUM_VARIACAO = 1    // Quanto o saldo mudou na ultima janela
};

input bool        InpUsarAcumulado = true;            // Validar pelo delta acumulado
input EModoAcum   InpModoAcum      = ACUM_VARIACAO;   // Nivel absoluto ou variacao recente
input EAncoraAcum InpAncoraAcum    = ACUM_INICIO_DIA; // De onde comecar a acumular
input int         InpAcumJanelaSeg = 600;             // [variacao] janela de comparacao (segundos)
input long        InpAcumMinimo    = 500;             // Abaixo disso o acumulado nao opina

//--- Ancora da ordem limite
enum EAncoraLimite
{
   ANCORA_PRECO_ATUAL     = 0,  // Offset a partir do preco atual (pullback raso)
   ANCORA_INICIO_AGRESSAO = 1   // Offset a partir de onde a rajada comecou
};

//--- Ordem
input bool          InpUsarLimite   = true;   // Entrar por limite (false = a mercado)
input EAncoraLimite InpAncora       = ANCORA_INICIO_AGRESSAO; // De onde medir o offset
input int    InpLimitOffset      = 250;    // [limite] distancia da ancora (pontos)
input int    InpFatiaMs          = 1000;   // [ancora rajada] tamanho da fatia de analise (ms)
input double InpTolRajada        = 0.30;   // [ancora rajada] quanto uma fatia pode remar contra (0.30 = 30%)
input int    InpOrderValidBarras = 3;      // [limite] validade da ordem, em barras do grafico
input double InpLots             = 1.0;    // Contratos por operacao
input int    InpStopPoints       = 120;    // Stop em pontos
input int    InpTakePoints       = 75;     // Alvo em pontos

//--- Trailing por DEGRAU (roda a cada tick, fora do acelerador de 1s).
//--- Desligue InpUsarTrailing para operar so com o take fixo.
input bool   InpUsarTrailing     = true;   // false = sai apenas no stop ou no take
input int    InpBreakevenEm      = 50;     // Lucro que dispara a protecao da entrada
input int    InpTravaInicial     = 25;     // Pontos acima da entrada onde o stop pousa
input int    InpDegrauPts        = 5;      // A cada N pontos que o preco andar, o stop anda N

//--- Filtro de horario
input bool   InpUseTimeFilter    = true;   // Ativar filtro de horario
input int    InpStartHour        = 9;      // Hora inicial (servidor)
input int    InpEndHour          = 17;     // Hora final (servidor)

//--- MODO CAUTELOSO (mercado indo e voltando)
//--- Reversao = o preco vira de direcao andando ao menos InpChopPts contra
//--- o ultimo topo/fundo. Nao bloqueia: so exige mais sinais concordando.
input bool   InpUsarFiltroChop   = true;   // Apertar a entrada quando o mercado vai e volta
input int    InpChopJanelaMin    = 30;     // Janela de leitura (minutos)
input int    InpChopPts          = 200;    // Recuo minimo para contar uma reversao (pontos)
input int    InpChopReversoes    = 2;      // Reversoes na janela que ligam o modo cauteloso
input int    InpChopHoldMin      = 20;     // Fica cauteloso por no minimo (minutos)
input int    InpChopMinSinais    = 3;      // Sinais concordando exigidos no modo cauteloso

//--- Controle de frequencia
input int    InpMinSegEntre      = 300;    // Segundos minimos entre uma entrada e a proxima

//--- Seguranca
input bool   InpExigirHedging    = true;   // Recusar carga em conta netting

//--- Painel no grafico
input bool   InpMostrarPainel    = true;   // Mostrar painel de leitura no grafico
input int    InpPainelX          = 14;     // Posicao X do painel (pixels)
input int    InpPainelY          = 26;     // Posicao Y do painel (pixels)
input color  InpCorTexto         = clrSilver;      // Cor do texto
input color  InpCorCompra        = clrMediumSeaGreen; // Cor do lado comprador
input color  InpCorVenda         = clrIndianRed;     // Cor do lado vendedor
input color  InpCorFundo         = C'22,22,26';      // Cor de fundo do painel

//--- Operacional
input int    InpMagic            = 470791;
input int    InpSlippage         = 20;
input bool   InpLog              = true;   // Registrar sinais no log
input bool   InpLogDiag          = true;   // Registrar no log, periodicamente, por que NAO entrou
input int    InpLogDiagSeg       = 30;     // Intervalo do diagnostico (segundos)

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
input double InpRajFator      = 2.5;    // Volume da janela >= fator x volume normal
input double InpRajDominioPct = 80;     // % do volume agredido do lado contrario a ordem
input int    InpRajNiveis     = 0;      // Niveis (ticks) contra a ordem (0 = ignora o deslocamento)
input int    InpRajMediaN     = 30;     // Barras M1 para medir o volume normal

//--- estado da regra de cancelamento por agressao
double   g_rajFator  = 0.0;   // ultima leitura, em x o volume normal
datetime g_rajUltSeg = 0;     // leitura no maximo 1x por segundo

//+------------------------------------------------------------------+
CTrade   trade;

//--- delta acumulado da sessao
long     deltaAcum  = 0;
ulong    acumAteMs  = 0;      // ate que instante ja foi acumulado
datetime diaDoAcum  = 0;      // dia a que o acumulado pertence

//--- historico do acumulado, um ponto por segundo, em buffer circular.
//--- Serve para medir a VARIACAO do saldo na janela, que e o que
//--- diz quem esta ganhando AGORA. O nivel absoluto so diz quem
//--- ganhou desde a abertura, e isso trava num lado so.
long     acumHist[];
int      acumHistN   = 0;
ulong    acumHistSeg = 0;     // ultimo segundo gravado
int      acumHistCheios = 0;
long     acumVariacao = 0;    // deltaAcum de agora menos o de InpAcumJanelaSeg atras
datetime horaUltimaEntrada = 0;
ulong    ultimaAvaliacaoMs = 0;

//--- modo cauteloso
datetime chopUltBarra = 0;    // ultima barra M1 ja lida
datetime chopAte      = 0;    // cauteloso ate este instante
bool     chopAtivo    = false;
int      chopRev      = 0;    // reversoes contadas na ultima leitura
int      sinaisAtivos = 0;    // quantos dos 3 sinais estao ligados
int      minSinaisAtual = 0;  // sinais exigidos AGORA (muda no modo cauteloso)

//--- JANELA BASE DESLIZANTE
//--- negocios por segundo num buffer circular. Em vez de reler a
//--- janela inteira a cada avaliacao, soma o segundo que entrou e
//--- subtrai o que saiu pela cauda.
long     baseSeg[];           // negocios em cada segundo da janela
int      baseN      = 0;      // tamanho do buffer (= InpJanelaBaseSeg)
long     baseTotal  = 0;      // soma corrente da janela
int      baseCheios = 0;      // segundos ja preenchidos (aquecimento)
ulong    baseUltSeg = 0;      // ultimo segundo contabilizado

//--- resumo da fita numa janela
struct TapeStats
{
   bool   valido;
   int    negocios;      // quantidade de negocios
   long   volCompra;     // volume agredido na compra
   long   volVenda;      // volume agredido na venda
   long   volNeutro;     // volume sem agressor identificavel (conta no total, nao no delta)
   long   volGrandesLiq; // volume liquido dos negocios grandes (compra - venda)
   long   maiorLote;     // maior negocio individual da janela
   double precoInicio;   // preco do primeiro negocio da janela
   double precoFim;      // preco do ultimo negocio da janela
   double precoMax;      // maior preco negociado na janela
   double precoMin;      // menor preco negociado na janela
};


//--- prototipo: o painel e definido mais abaixo
void RemoverPainel();

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- este EA pressupoe conta hedging: em netting varios EAs no mesmo
   //--- simbolo compartilhariam a mesma posicao e sobrescreveriam SL/TP
   if(InpExigirHedging)
   {
      ENUM_ACCOUNT_MARGIN_MODE modo =
         (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
      if(modo != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      {
         Print("Conta NAO e hedging - este EA nao deve rodar junto com outros "
               "no mesmo simbolo (posicao e SL/TP seriam compartilhados)");
         return INIT_FAILED;
      }
   }

   int ativos = (InpUsarGrandes ? 1 : 0) + (InpUsarVelocidade ? 1 : 0) +
                (InpUsarDesequilibrio ? 1 : 0);
   if(ativos == 0)
   {
      Print("Nenhum sinal ativo");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMinSinais < 1 || InpMinSinais > ativos)
   {
      PrintFormat("InpMinSinais (%d) precisa ficar entre 1 e %d (sinais ativos)",
                  InpMinSinais, ativos);
      return INIT_PARAMETERS_INCORRECT;
   }
   sinaisAtivos   = ativos;
   minSinaisAtual = InpMinSinais;

   if(InpUsarFiltroChop)
   {
      if(InpChopJanelaMin < 5 || InpChopPts <= 0 || InpChopReversoes < 1 ||
         InpChopHoldMin < 0 || InpChopMinSinais < 1)
      {
         Print("Parametros do modo cauteloso invalidos (janela>=5, pontos>0, "
               "reversoes>=1, hold>=0, sinais>=1)");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpChopMinSinais > ativos)
         PrintFormat("Atencao: o modo cauteloso pede %d sinais, mas so ha %d ligados - "
                     "sera usado %d", InpChopMinSinais, ativos, ativos);
      else if(InpChopMinSinais <= InpMinSinais)
         Print("Atencao: InpChopMinSinais nao e maior que InpMinSinais - "
               "o modo cauteloso nao vai apertar nada");
      PrintFormat("Modo cauteloso: %d reversoes de %d+ pts em %d min liga a cautela "
                  "(exige %d sinais, fica ligado ao menos %d min)",
                  InpChopReversoes, InpChopPts, InpChopJanelaMin,
                  MathMin(InpChopMinSinais, ativos), InpChopHoldMin);
   }
   else
      Print("Modo cauteloso DESLIGADO");

   if(InpUsarLimite && InpOrderValidBarras < 1)
   {
      Print("Validade da ordem limite deve ser de ao menos 1 barra");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpJanelaSeg < 3 || InpJanelaBaseSeg <= InpJanelaSeg)
   {
      Print("Janela curta deve ser >= 3s e menor que a janela base");
      return INIT_PARAMETERS_INCORRECT;
   }
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

   //--- buffer circular da janela base
   baseN = InpJanelaBaseSeg;
   if(ArrayResize(baseSeg, baseN) != baseN)
   {
      Print("Falha ao alocar o buffer da janela base");
      return INIT_FAILED;
   }
   ArrayInitialize(baseSeg, 0);
   baseTotal  = 0;
   baseCheios = 0;
   baseUltSeg = 0;

   //--- buffer circular do historico do acumulado
   if(InpUsarAcumulado && InpModoAcum == ACUM_VARIACAO)
   {
      acumHistN = InpAcumJanelaSeg;
      if(acumHistN < 30)   acumHistN = 30;
      if(acumHistN > 7200) acumHistN = 7200;
      if(ArrayResize(acumHist, acumHistN) != acumHistN)
      {
         Print("Falha ao alocar o historico do acumulado");
         return INIT_FAILED;
      }
      ArrayInitialize(acumHist, 0);
      acumHistSeg    = 0;
      acumHistCheios = 0;
      acumVariacao   = 0;
   }

   if(InpBootstrapBase) BootstrapBase();

   PrintFormat("Sinais: grandes=%s | velocidade=%s | desequilibrio=%s | exige %d concordando",
               InpUsarGrandes       ? "ON" : "OFF",
               InpUsarVelocidade    ? "ON" : "OFF",
               InpUsarDesequilibrio ? "ON" : "OFF",
               InpMinSinais);
   PrintFormat("Janela de %ds | referencia deslizante de %ds | lote grande >= %d contratos",
               InpJanelaSeg, InpJanelaBaseSeg, (int)InpLoteGrande);
   if(InpUsarTrailing)
   {
      double tickSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSz <= 0.0) tickSz = _Point;
      double tickPts = tickSz / _Point;

      double folga = InpBreakevenEm - InpTravaInicial;

      PrintFormat("Trailing: em +%d o stop vai para a entrada +%d pontos",
                  InpBreakevenEm, InpTravaInicial);
      PrintFormat("Depois disso, a cada %d pts que o preco andar o stop anda %d "
                  "(degrau = %d tick(s))",
                  InpDegrauPts, InpDegrauPts,
                  (int)MathRound(InpDegrauPts / tickPts));
      PrintFormat("Folga constante entre preco e stop: %.0f pontos", folga);

      //--- o degrau precisa ser multiplo do tick, senao o arredondamento
      //--- do NormalizePrice engole parte dele e o stop trava
      if(MathAbs(InpDegrauPts / tickPts - MathRound(InpDegrauPts / tickPts)) > 0.001)
         PrintFormat("Atencao: o degrau de %d pontos nao e multiplo do tick de %.0f - "
                     "o arredondamento vai distorcer o avanco",
                     InpDegrauPts, tickPts);

      //--- folga menor que o nivel minimo: o stop ficaria perto demais do
      //--- preco e a corretora recusaria toda modificacao, em silencio
      long nivelMin = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      if(nivelMin > 0 && folga <= (double)nivelMin)
         PrintFormat("ERRO: a folga de %.0f pontos nao supera o nivel minimo da "
                     "corretora (%d) - o trailing NUNCA sera aplicado",
                     folga, (int)nivelMin);
      if(folga <= 0.0)
         Print("ERRO: a trava pousa em cima ou acima do preco - reveja "
               "InpBreakevenEm e InpTravaInicial");

      //--- a trava tambem precisa ser multipla do tick
      if(MathAbs(InpTravaInicial / tickPts - MathRound(InpTravaInicial / tickPts)) > 0.001)
         PrintFormat("Atencao: a trava de %d pontos nao e multipla do tick de %.0f",
                     InpTravaInicial, tickPts);
   }
   else if(InpTakePoints > 300)
      PrintFormat("Atencao: trailing desligado com alvo de %d pontos. "
                  "Sem o trailing, o alvo e a unica saida de lucro - "
                  "reveja se %d pontos e alcancavel.",
                  InpTakePoints, InpTakePoints);
   if(InpUsarAcumulado && InpModoAcum == ACUM_NIVEL)
      Print("ATENCAO: acumulado em modo NIVEL. Depois de algumas horas ele "
            "nao volta mais perto de zero e vira uma trava fixa num lado so. "
            "Se o robo parar de operar, e provavelmente isto.");
   if(InpUsarAcumulado)
      PrintFormat("Acumulado %s | neutro abaixo de %d contratos",
                  InpAncoraAcum == ACUM_INICIO_DIA ? "desde a abertura do pregao"
                                                   : "desde a carga do EA",
                  (int)InpAcumMinimo);

   //--- ficha do simbolo
   long nivelMinStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   PrintFormat("--- %s | digitos=%d | point=%.*f | tick=%.*f | nivel minimo de stop=%d pontos",
               _Symbol, _Digits, _Digits, _Point,
               _Digits, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
               (int)nivelMinStop);

   //--- o Entrar descarta a ordem quando o stop OU o alvo nao alcancam
   //--- esse nivel. Melhor saber na carga do que descobrir depois com o
   //--- robo em silencio.
   if(nivelMinStop > 0 && (InpStopPoints < nivelMinStop || InpTakePoints < nivelMinStop))
      PrintFormat("ERRO: stop %d / alvo %d nao alcancam o nivel minimo de %d pontos - "
                  "NENHUMA ordem sera enviada. Suba o menor dos dois.",
                  InpStopPoints, InpTakePoints, (int)nivelMinStop);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   RemoverPainel();
}

//+------------------------------------------------------------------+
//| JANELA BASE DESLIZANTE                                           |
//|                                                                   |
//| A media de negocios/segundo so precisa da CONTAGEM por segundo.   |
//| Em vez de reler a janela inteira a cada avaliacao, cada segundo e |
//| contado uma unica vez e guardado num buffer circular; a soma      |
//| corrente avanca somando o que entrou e subtraindo o que saiu.     |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CLASSIFICACAO DO AGRESSOR                                        |
//|                                                                   |
//| Ponto unico onde se decide de que lado foi a agressao. Todas as   |
//| leituras (fita, contagem, acumulado) passam por aqui, para que    |
//| nenhuma use um criterio diferente da outra.                       |
//|                                                                   |
//| Ordem de decisao:                                                 |
//|   1. flag BUY ou SELL do feed - e a informacao da bolsa           |
//|   2. preco negociado contra o book do proprio tick                |
//|      (bateu no ask = comprador agrediu; no bid = vendedor)        |
//|   3. uptick/downtick contra o negocio anterior                    |
//|                                                                   |
//| Devolve +1 compra, -1 venda, 0 realmente indefinido (cruzada no   |
//| meio do book, sem referencia anterior). O volume do indefinido    |
//| NAO se perde: entra em volNeutro e conta no volume total, so nao  |
//| entra no delta - inventar um lado seria pior que admitir que nao  |
//| da para saber.                                                    |
//+------------------------------------------------------------------+
int LadoAgressor(const MqlTick &t, double &ultPreco)
{
   bool compra = (t.flags & TICK_FLAG_BUY)  != 0;
   bool venda  = (t.flags & TICK_FLAG_SELL) != 0;

   int lado = 0;

   if(compra != venda)
      lado = compra ? 1 : -1;
   else if(t.last > 0.0)
   {
      //--- sem flag util: compara com o book daquele instante
      if(t.ask > 0.0 && t.last >= t.ask)      lado =  1;
      else if(t.bid > 0.0 && t.last <= t.bid) lado = -1;
      //--- book indisponivel: regra do uptick
      else if(ultPreco > 0.0 && t.last > ultPreco) lado =  1;
      else if(ultPreco > 0.0 && t.last < ultPreco) lado = -1;
   }

   if(t.last > 0.0) ultPreco = t.last;
   return lado;
}

//--- quantos negocios validos houve no intervalo.
//--- Usa os MESMOS filtros do LerFita, senao as duas contagens ficam
//--- em escalas diferentes e o fator de velocidade sai distorcido.
int ContarNegocios(ulong deMs, ulong ateMs)
{
   if(ateMs < deMs) return 0;

   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, deMs, ateMs);
   if(n <= 0) return 0;

   int c = 0;
   for(int i = 0; i < n; i++)
   {
      long v = (long)ticks[i].volume;
      if(v <= 0) continue;
      if(InpLoteTeto > 0 && v > InpLoteTeto) continue;

      //--- negocio e negocio, tenha agressor identificado ou nao:
      //--- a velocidade da fita mede ritmo, nao direcao
      c++;
   }
   return c;
}

//--- enche a janela do historico uma unica vez, na carga do EA.
//--- Paga a leitura pesada uma vez para ja comecar com referencia cheia.
void BootstrapBase()
{
   MqlTick agora;
   if(!SymbolInfoTick(_Symbol, agora) || agora.time_msc == 0) return;

   //--- o segundo corrente ainda esta em curso: so conta segundos FECHADOS
   ulong segAtual = agora.time_msc / 1000;
   if(segAtual == 0) return;
   segAtual -= 1;
   if(segAtual <= (ulong)baseN) return;

   ulong iniSeg = segAtual - (ulong)baseN + 1;

   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE,
                          iniSeg * 1000, segAtual * 1000 + 999);
   if(n <= 0)
   {
      if(InpLog) Print("Bootstrap da janela base: sem ticks no historico");
      return;
   }

   for(int i = 0; i < n; i++)
   {
      long v = (long)ticks[i].volume;
      if(v <= 0) continue;
      if(InpLoteTeto > 0 && v > InpLoteTeto) continue;

      ulong seg = ticks[i].time_msc / 1000;
      if(seg < iniSeg || seg > segAtual) continue;

      baseSeg[(int)(seg % (ulong)baseN)]++;
      baseTotal++;
   }

   baseCheios = baseN;
   baseUltSeg = segAtual;

   if(InpLog)
      PrintFormat("Janela base carregada do historico: %d negocios em %ds (%.1f/s)",
                  (int)baseTotal, baseN, (double)baseTotal / baseN);
}

void AtualizarBase(ulong agoraMs)
{
   if(agoraMs == 0 || baseN <= 0) return;

   //--- o segundo corrente ainda esta em curso e seria contado pela metade.
   //--- Contar so segundos FECHADOS: senao a media de referencia sai
   //--- subestimada e o fator de velocidade fica inflado.
   ulong segAtual = agoraMs / 1000;
   if(segAtual == 0) return;
   segAtual -= 1;

   //--- primeira chamada sem bootstrap: ancora e comeca a encher daqui
   if(baseUltSeg == 0) { baseUltSeg = segAtual; return; }
   if(segAtual <= baseUltSeg) return;

   //--- buraco grande (pregao fechado, EA parado, queda de conexao, troca de
   //--- dia): recuperar segundo a segundo travaria o terminal, e o que havia
   //--- ja nao serve de referencia
   if(segAtual - baseUltSeg >= (ulong)MathMin(baseN, 120))
   {
      ArrayInitialize(baseSeg, 0);
      baseTotal  = 0;
      baseCheios = 0;
      baseUltSeg = segAtual;
      if(InpLog) Print("Janela base reiniciada (intervalo grande demais para recuperar)");
      return;
   }

   for(ulong s = baseUltSeg + 1; s <= segAtual; s++)
   {
      int idx = (int)(s % (ulong)baseN);
      baseTotal -= baseSeg[idx];                 // sai o segundo que expirou
      baseSeg[idx] = ContarNegocios(s * 1000, s * 1000 + 999);
      baseTotal += baseSeg[idx];
      if(baseCheios < baseN) baseCheios++;
   }
   baseUltSeg = segAtual;
}

//--- negocios por segundo na janela de referencia (0 se ainda aquecendo)
double VelocidadeBase()
{
   if(baseCheios <= 0) return 0.0;
   return (double)baseTotal / baseCheios;
}

//+------------------------------------------------------------------+
//| DELTA ACUMULADO DA SESSAO                                        |
//|                                                                   |
//| Soma de todo o volume agredido na compra menos o agredido na      |
//| venda, desde a ancora escolhida. Diz qual lado dominou a sessao.  |
//|                                                                   |
//| Calculado uma vez do historico e depois so incrementado, para     |
//| nao reler o dia inteiro a cada segundo.                           |
//+------------------------------------------------------------------+
long DeltaNoIntervalo(ulong deMs, ulong ateMs)
{
   if(ateMs <= deMs) return 0;

   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, deMs, ateMs);
   if(n <= 0) return 0;

   long   d = 0;
   double ultPreco = 0.0;
   for(int i = 0; i < n; i++)
   {
      long v = (long)ticks[i].volume;
      if(v <= 0) continue;
      if(InpLoteTeto > 0 && v > InpLoteTeto) continue;

      int lado = LadoAgressor(ticks[i], ultPreco);
      if(lado != 0) d += lado * v;
   }
   return d;
}

void AtualizarAcumulado(ulong agoraMs)
{
   if(!InpUsarAcumulado || agoraMs == 0) return;

   datetime hoje = iTime(_Symbol, PERIOD_D1, 0);

   //--- virou o dia: zera e recomeca
   if(InpAncoraAcum == ACUM_INICIO_DIA && hoje != diaDoAcum)
   {
      diaDoAcum = hoje;
      acumAteMs = 0;
      deltaAcum = 0;
   }

   //--- o milissegundo corrente pode ainda estar recebendo negocios.
   //--- Fechar nele perderia os que chegarem depois da leitura, porque a
   //--- proxima comeca em +1. Para em -1 e deixa o ms atual para a proxima.
   if(agoraMs == 0) return;
   ulong ateMs = agoraMs - 1;

   //--- primeira vez: reconstroi do historico
   if(acumAteMs == 0)
   {
      ulong iniMs = (InpAncoraAcum == ACUM_INICIO_DIA && hoje > 0)
                    ? (ulong)hoje * 1000
                    : ateMs;

      deltaAcum = (iniMs < ateMs) ? DeltaNoIntervalo(iniMs, ateMs) : 0;
      acumAteMs = ateMs;
      diaDoAcum = hoje;

      if(InpLog)
         PrintFormat("Delta acumulado iniciado em %d contratos (%s)",
                     (int)deltaAcum,
                     InpAncoraAcum == ACUM_INICIO_DIA ? "desde a abertura" : "desde agora");
      return;
   }

   //--- incremento: so o que entrou desde a ultima leitura
   if(ateMs > acumAteMs)
   {
      deltaAcum += DeltaNoIntervalo(acumAteMs + 1, ateMs);
      acumAteMs = ateMs;
   }

   //--- grava o ponto deste segundo e mede a variacao na janela.
   //--- O valor que esta prestes a ser sobrescrito no buffer
   //--- circular E exatamente o de acumHistN segundos atras.
   if(InpModoAcum == ACUM_VARIACAO && acumHistN > 0)
   {
      ulong seg = ateMs / 1000;
      if(seg > acumHistSeg)
      {
         //--- buraco maior que a janela: o historico nao serve mais
         if(acumHistSeg > 0 && seg - acumHistSeg >= (ulong)acumHistN)
         {
            ArrayInitialize(acumHist, 0);
            acumHistCheios = 0;
         }

         int idx = (int)(seg % (ulong)acumHistN);
         long antigo = acumHist[idx];
         acumHist[idx] = deltaAcum;

         if(acumHistCheios >= acumHistN)
            acumVariacao = deltaAcum - antigo;
         else
         {
            acumHistCheios++;
            acumVariacao = 0;      // ainda aquecendo: nao opina
         }

         acumHistSeg = seg;
      }
   }
}

//--- +1 comprador dominando, -1 vendedor, 0 sem opiniao
int LadoAcumulado()
{
   if(!InpUsarAcumulado) return 0;

   //--- NIVEL: o saldo desde a abertura. Util para entender o dia,
   //--- ruim como filtro - depois de algumas horas ele nunca mais
   //--- volta perto de zero e vira uma trava fixa num lado so.
   if(InpModoAcum == ACUM_NIVEL)
   {
      if(MathAbs(deltaAcum) < InpAcumMinimo) return 0;
      return (deltaAcum > 0) ? 1 : -1;
   }

   //--- VARIACAO: quanto o saldo mudou na ultima janela. Volta a
   //--- zero sozinho quando o fluxo equilibra, entao pode barrar
   //--- hoje e liberar daqui a dez minutos.
   if(acumHistCheios < acumHistN) return 0;   // ainda aquecendo
   if(MathAbs(acumVariacao) < InpAcumMinimo) return 0;
   return (acumVariacao > 0) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| LEITURA DA FITA                                                  |
//| Resume os negocios dos ultimos N segundos.                       |
//+------------------------------------------------------------------+
TapeStats LerFita(int segundos, ulong fimMs)
{
   TapeStats t;
   t.valido = false;
   t.negocios = 0;
   t.volCompra = t.volVenda = t.volNeutro = t.volGrandesLiq = t.maiorLote = 0;
   t.precoInicio = t.precoFim = t.precoMax = t.precoMin = 0.0;

   if(fimMs == 0) return t;
   ulong inicioMs = (fimMs > (ulong)segundos * 1000) ? fimMs - (ulong)segundos * 1000 : 0;

   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, inicioMs, fimMs);
   if(n <= 0) return t;

   double ultPreco = 0.0;
   for(int i = 0; i < n; i++)
   {
      long v = (long)ticks[i].volume;
      if(v <= 0) continue;

      // negocio absurdo: leilao de abertura/fechamento ou cruzada de balcao
      if(InpLoteTeto > 0 && v > InpLoteTeto) continue;

      int lado = LadoAgressor(ticks[i], ultPreco);

      t.negocios++;
      if(lado > 0)      t.volCompra += v;
      else if(lado < 0) t.volVenda  += v;
      else              t.volNeutro += v;   // volume preservado, sem lado

      //--- primeiro, ultimo e extremos do preco negociado na janela
      if(t.precoInicio <= 0.0) t.precoInicio = ticks[i].last;
      if(ticks[i].last > 0.0)
      {
         t.precoFim = ticks[i].last;
         if(t.precoMax <= 0.0 || ticks[i].last > t.precoMax) t.precoMax = ticks[i].last;
         if(t.precoMin <= 0.0 || ticks[i].last < t.precoMin) t.precoMin = ticks[i].last;
      }

      if(v > t.maiorLote) t.maiorLote = v;

      //--- negocio grande entra na conta liquida dos grandes
      if(v >= InpLoteGrande && lado != 0)
         t.volGrandesLiq += lado * v;
   }

   t.valido = (t.negocios > 0);
   return t;
}

//+------------------------------------------------------------------+
//| SINAL 1 - GRANDES LOTES                                          |
//| Quem manda lote grande move o mercado. Segue a direcao deles.    |
//+------------------------------------------------------------------+
int SinalGrandes(const TapeStats &t)
{
   if(!InpUsarGrandes || !t.valido) return 0;

   // fita rala nao e fita: um negocio solitario nao forma agressao
   if(t.negocios < InpMinNegocios) return 0;

   if(MathAbs(t.volGrandesLiq) < InpVolGrandesMin) return 0;

   int dir = (t.volGrandesLiq > 0) ? 1 : -1;

   if(InpLog)
      PrintFormat("GRANDES | liquido %d contratos (maior lote %d) -> %s",
                  (int)t.volGrandesLiq, (int)t.maiorLote, dir > 0 ? "COMPRA" : "VENDA");
   return dir;
}

//+------------------------------------------------------------------+
//| SINAL 2 - VELOCIDADE DA FITA                                     |
//| Fita acelerando indica que algo esta acontecendo agora.          |
//| A direcao vem do lado dominante na propria janela.               |
//|                                                                   |
//| A media de referencia vem da janela deslizante, nao de uma        |
//| releitura do historico.                                           |
//+------------------------------------------------------------------+
int SinalVelocidade(const TapeStats &curta)
{
   if(!InpUsarVelocidade || !curta.valido) return 0;
   if(curta.negocios < InpMinNegocios) return 0;

   //--- janela base curta demais ainda: a media nao e confiavel
   if(baseCheios < InpJanelaSeg * 4) return 0;

   double velCurta = (double)curta.negocios / InpJanelaSeg;
   double velBase  = VelocidadeBase();
   if(velBase <= 0.0) return 0;

   double fator = velCurta / velBase;
   if(fator < InpFatorVelocidade) return 0;

   long total = curta.volCompra + curta.volVenda + curta.volNeutro;
   if(total <= 0) return 0;

   //--- aceleracao sem lado definido nao diz nada
   double saldo = (double)(curta.volCompra - curta.volVenda) / total;
   if(MathAbs(saldo) < 0.20) return 0;

   int dir = (saldo > 0) ? 1 : -1;

   if(InpLog)
      PrintFormat("VELOCIDADE | %.1f negocios/s contra media de %.1f (fator %.1fx) -> %s",
                  velCurta, velBase, fator, dir > 0 ? "COMPRA" : "VENDA");
   return dir;
}

//+------------------------------------------------------------------+
//| SINAL 3 - DESEQUILIBRIO DE AGRESSAO                              |
//| Um lado agredindo muito mais que o outro na janela.              |
//+------------------------------------------------------------------+
int SinalDesequilibrio(const TapeStats &t)
{
   if(!InpUsarDesequilibrio || !t.valido) return 0;

   if(t.negocios < InpMinNegocios) return 0;

   //--- o neutro entra no divisor: se metade da fita veio sem agressor
   //--- identificavel, nao se pode afirmar que ha desequilibrio
   long total = t.volCompra + t.volVenda + t.volNeutro;
   if(total < InpVolMinJanela) return 0;

   double saldo = (double)(t.volCompra - t.volVenda) / total;
   if(MathAbs(saldo) < InpDesequilibrioMin) return 0;

   int dir = (saldo > 0) ? 1 : -1;

   if(InpLog)
      PrintFormat("DESEQUILIBRIO | compra %d x venda %d x neutro %d (saldo %.0f%%) -> %s",
                  (int)t.volCompra, (int)t.volVenda, (int)t.volNeutro, saldo * 100.0,
                  dir > 0 ? "COMPRA" : "VENDA");
   return dir;
}

//+------------------------------------------------------------------+
//| INICIO DA RAJADA                                                 |
//|                                                                   |
//| Varre a janela de TRAS PARA FRENTE em fatias de InpFatiaMs e      |
//| acumula o delta de cada uma. Enquanto a fatia concorda com a      |
//| direcao do sinal (ou e neutra), ela faz parte da rajada. Na       |
//| primeira fatia que rema contra com forca, a varredura para: a     |
//| rajada comecou depois dela.                                        |
//|                                                                   |
//| Devolve o preco do primeiro negocio da rajada, ou 0 se nao achar. |
//+------------------------------------------------------------------+
double InicioRajada(int direcao, ulong fimMs)
{
   if(fimMs == 0 || direcao == 0) return 0.0;

   MqlTick ticks[];
   ulong iniMs = (fimMs > (ulong)InpJanelaSeg * 1000) ? fimMs - (ulong)InpJanelaSeg * 1000 : 0;
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, iniMs, fimMs);
   if(n <= 0) return 0.0;

   int    idx = n - 1;        // comeca no negocio mais recente
   double precoRajada = 0.0;
   int    fatias = 0;

   while(idx >= 0)
   {
      //--- limites da fatia que termina em ticks[idx]
      ulong fimFatia = ticks[idx].time_msc;
      ulong iniFatia = (fimFatia > (ulong)InpFatiaMs) ? fimFatia - (ulong)InpFatiaMs : 0;

      long delta = 0, vol = 0;
      int  j = idx;
      while(j >= 0 && ticks[j].time_msc >= iniFatia)
      {
         long q = (long)ticks[j].volume;
         if(q > 0 && !(InpLoteTeto > 0 && q > InpLoteTeto))
         {
            //--- aqui a varredura e de tras para frente, entao a regra do
            //--- uptick nao se aplica: usa so flag e book
            double semRef = 0.0;
            int lado = LadoAgressor(ticks[j], semRef);
            delta += lado * q;
            vol   += q;          // volume neutro dilui a fatia, nao some
         }
         j--;
      }

      //--- fatia remando contra a direcao: a rajada comeca depois dela
      if(vol > 0)
      {
         double saldo = (double)delta / vol;
         if(saldo * direcao < -InpTolRajada) break;
      }

      //--- fatia faz parte da rajada: guarda o preco do primeiro negocio dela
      int primeiro = j + 1;
      if(primeiro >= 0 && primeiro < n && ticks[primeiro].last > 0.0)
         precoRajada = ticks[primeiro].last;

      fatias++;
      idx = j;
   }

   if(InpLog && precoRajada > 0.0)
      PrintFormat("Rajada: %d fatia(s) de %dms | comecou em %.0f",
                  fatias, InpFatiaMs, precoRajada);

   return precoRajada;
}

//+------------------------------------------------------------------+
//| Utilitarios                                                      |
//+------------------------------------------------------------------+
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

void CancelExpiredOrders()
{
   if(InpOrderValidBarras <= 0) return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      datetime criada = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(criada <= 0) continue;

      //--- validade em BARRAS do grafico em que o EA esta: acompanha o
      //--- tempo grafico em vez de ser um numero fixo de segundos.
      //--- iBarShift devolve -1 quando a ordem e mais antiga que o
      //--- historico carregado. Uma ordem assim e velha, nao nova:
      //--- sem este tratamento ela nunca expiraria e travaria o robo
      //--- em ORDEM PENDENTE para sempre.
      int barras = iBarShift(_Symbol, _Period, criada, false);
      if(barras < 0 || barras >= InpOrderValidBarras)
      {
         trade.OrderDelete(ticket);
         if(InpLog)
            PrintFormat("Limite cancelada: %s (validade %d barras)",
                        (barras < 0) ? "mais antiga que o historico do grafico"
                                     : StringFormat("%d barra(s) sem execucao", barras),
                        InpOrderValidBarras);
      }
   }
}

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

//--- cotacao atual, com o ultimo negocio como alternativa
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
      if(!chopAtivo && InpLog)
         PrintFormat("MODO CAUTELOSO ligado: %d reversoes de %d+ pts em %d min "
                     "(exige %d sinais concordando)",
                     chopRev, InpChopPts, InpChopJanelaMin,
                     MathMin(InpChopMinSinais, sinaisAtivos));
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
      if(InpLog)
         Print("Modo cauteloso desligado: mercado voltou a andar");
   }
   return chopAtivo;
}

//+------------------------------------------------------------------+
//| PAINEL NO GRAFICO                                                |
//+------------------------------------------------------------------+
#define PFX "FitaP_"

void Rotulo(string id, int x, int y, string txt, color cor, int tam = 9, string fonte = "Consolas")
{
   string n = PFX + id;
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_BACK, false);
      ObjectSetInteger(0, n, OBJPROP_ZORDER, 10);  // na frente do fundo
   }
   ObjectSetString (0, n, OBJPROP_FONT, fonte);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, tam);
   ObjectSetInteger(0, n, OBJPROP_COLOR, cor);
   ObjectSetString (0, n, OBJPROP_TEXT, txt);
}

void Retangulo(string id, int x, int y, int larg, int alt, color cor, bool atras)
{
   string n = PFX + id;
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, n, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, n, OBJPROP_ZORDER, 0);   // atras dos rotulos
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, MathMax(larg, 1));
   ObjectSetInteger(0, n, OBJPROP_YSIZE, MathMax(alt, 1));
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, cor);
   ObjectSetInteger(0, n, OBJPROP_COLOR,   cor);
   ObjectSetInteger(0, n, OBJPROP_BACK,    atras);
}

void RemoverPainel()
{
   ObjectsDeleteAll(0, PFX);
   ChartRedraw(0);
}

//--- marca de condicao atendida
string Marca(bool ok) { return ok ? "[x]" : "[ ]"; }

//--- nome curto da direcao
string NomeDir(int d) { return (d > 0) ? "COMPRA" : ((d < 0) ? "VENDA" : "--"); }
color  CorDir(int d)  { return (d > 0) ? InpCorCompra : ((d < 0) ? InpCorVenda : InpCorTexto); }

void AtualizarPainel(const TapeStats &curta,
                     int s1, int s2, int s3, string estado)
{
   if(!InpMostrarPainel) return;

   int X = InpPainelX, Y = InpPainelY;
   int L = 286;              // largura do painel
   int lin = 17;             // altura de cada linha

   Retangulo("bg", X - 10, Y - 10, L, 268, InpCorFundo, false);

   int y = Y;

   //--- cabecalho
   Rotulo("tit", X, y, StringFormat("LEITURA DE FITA          %ds", InpJanelaSeg),
          InpCorTexto, 9, "Consolas Bold");
   y += lin + 2;

   //--- barra de agressao (o neutro entra no total, como nos sinais)
   long total = curta.volCompra + curta.volVenda + curta.volNeutro;
   double fracC = (total > 0) ? (double)curta.volCompra / total : 0.5;
   double fracV = (total > 0) ? (double)curta.volVenda  / total : 0.5;
   int larguraBarra = L - 16;
   int wC = (int)MathRound(larguraBarra * fracC);
   int wV = (int)MathRound(larguraBarra * fracV);
   int wN = larguraBarra - wC - wV;          // fatia sem agressor identificado

   Retangulo("barC", X, y, wC, 12, InpCorCompra, false);
   Retangulo("barV", X + wC, y, wV, 12, InpCorVenda, false);
   Retangulo("barN", X + wC + wV, y, wN, 12, clrDimGray, false);
   y += 16;

   Rotulo("agr", X, y,
          StringFormat("AGRESSAO   C %3.0f%%   V %3.0f%%   ? %2.0f%%",
                       fracC * 100.0, fracV * 100.0,
                       (total > 0) ? 100.0 * curta.volNeutro / total : 0.0),
          (fracC >= fracV) ? InpCorCompra : InpCorVenda);
   y += lin;

   Rotulo("vol", X, y, StringFormat("Volume     %d contratos", (int)total), InpCorTexto);
   y += lin;

   double velC = (double)curta.negocios / InpJanelaSeg;
   double velB = VelocidadeBase();
   double fator = (velB > 0.0) ? velC / velB : 0.0;

   Rotulo("neg", X, y,
          StringFormat("Negocios   %d  (%.1f/s)", curta.negocios, velC), InpCorTexto);
   y += lin;

   //--- durante o aquecimento, mostra o preenchimento em vez do fator
   if(baseCheios < baseN)
      Rotulo("vel", X, y,
             StringFormat("Velocidade %.1fx  (base %d%%)",
                          fator, (int)(100.0 * baseCheios / baseN)),
             InpCorTexto);
   else
      Rotulo("vel", X, y,
             StringFormat("Velocidade %.1fx da media", fator),
             (fator >= InpFatorVelocidade) ? InpCorCompra : InpCorTexto);
   y += lin;

   Rotulo("gra", X, y,
          StringFormat("Grandes    %+d liquido  (max %d)",
                       (int)curta.volGrandesLiq, (int)curta.maiorLote),
          (MathAbs(curta.volGrandesLiq) >= InpVolGrandesMin)
            ? (curta.volGrandesLiq > 0 ? InpCorCompra : InpCorVenda) : InpCorTexto);
   y += lin + 6;

   //--- sinais
   Rotulo("sinT", X, y, "SINAIS", InpCorTexto, 9, "Consolas Bold");
   y += lin;

   Rotulo("sin1", X, y,
          StringFormat("%s Grandes lotes    %s",
                       Marca(s1 != 0), NomeDir(s1)), CorDir(s1));
   y += lin;
   Rotulo("sin2", X, y,
          StringFormat("%s Velocidade       %s",
                       Marca(s2 != 0), NomeDir(s2)), CorDir(s2));
   y += lin;
   Rotulo("sin3", X, y,
          StringFormat("%s Desequilibrio    %s",
                       Marca(s3 != 0), NomeDir(s3)), CorDir(s3));
   y += lin;

   int compras = (s1 > 0 ? 1 : 0) + (s2 > 0 ? 1 : 0) + (s3 > 0 ? 1 : 0);
   int vendas  = (s1 < 0 ? 1 : 0) + (s2 < 0 ? 1 : 0) + (s3 < 0 ? 1 : 0);
   int maior   = MathMax(compras, vendas);

   Rotulo("conc", X, y,
          StringFormat("Concordam  %d de %d necessarios%s", maior, minSinaisAtual,
                       chopAtivo ? " CAUT" : ""),
          (maior >= minSinaisAtual) ? InpCorCompra : (chopAtivo ? InpCorVenda : InpCorTexto));
   y += lin + 6;

   //--- contexto
   if(InpUsarAcumulado)
   {
      int lado = LadoAcumulado();
      if(InpModoAcum == ACUM_VARIACAO)
      {
         if(acumHistCheios < acumHistN)
            Rotulo("acum", X, y,
                   StringFormat("Acum %ds  aquecendo %d%%", InpAcumJanelaSeg,
                                (acumHistN > 0) ? (int)(100.0 * acumHistCheios / acumHistN) : 0),
                   InpCorTexto);
         else
            Rotulo("acum", X, y,
                   StringFormat("Acum %ds  %+d  %s", InpAcumJanelaSeg,
                                (int)acumVariacao, NomeDir(lado)),
                   CorDir(lado));
      }
      else
         Rotulo("acum", X, y,
                StringFormat("Acumulado  %+d  %s", (int)deltaAcum, NomeDir(lado)),
                CorDir(lado));
   }
   else
      Rotulo("acum", X, y, "Acumulado  filtro off", InpCorTexto);
   y += lin;

   Rotulo("est", X, y, StringFormat("Estado     %s", estado), InpCorTexto);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| TRAILING POR DEGRAU                                              |
//|                                                                   |
//| O stop nao persegue o preco continuamente: ele sobe em degraus do |
//| mesmo tamanho do avanco. A cada InpDegrauPts que o preco anda, o  |
//| stop anda InpDegrauPts. Com isso a FOLGA entre preco e stop fica  |
//| constante, definida no momento em que a entrada foi protegida.    |
//|                                                                   |
//| Comprado a 140.000, breakeven em +50, degrau de 25:               |
//|                                                                   |
//|   lucro   degraus   stop            folga                         |
//|   ----------------------------------------------                  |
//|   +50       0       entrada +5       45                           |
//|   +75       1       entrada +30      45                           |
//|   +100      2       entrada +55      45                           |
//|   +200      6       entrada +155     45                           |
//|                                                                   |
//| O calculo e absoluto, nao incremental: o stop e sempre deduzido   |
//| da entrada e do numero de degraus completos. Assim ele nao        |
//| acumula erro nem depende de o EA ter visto todos os ticks - se o  |
//| terminal ficar fora do ar por um tempo, na volta o stop pula      |
//| direto para o degrau correto.                                     |
//|                                                                   |
//| O preco de referencia e o lado pelo qual a posicao FECHA (bid     |
//| para comprado, ask para vendido) - usar o outro lado daria um     |
//| lucro que nao existe na hora de sair.                             |
//+------------------------------------------------------------------+
void GerenciarTrailing()
{
   if(!InpUsarTrailing) return;
   if(InpDegrauPts <= 0) return;

   double ask = 0.0, bid = 0.0;
   if(!GetQuotes(ask, bid)) return;

   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double tickSz    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSz <= 0.0) tickSz = _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;

      bool   isLong    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double entrada   = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopAtual = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);

      //--- preco pelo qual a posicao fecharia agora
      double precoSaida = isLong ? bid : ask;
      double lucroPts   = (isLong ? (precoSaida - entrada)
                                  : (entrada - precoSaida)) / _Point;

      //--- ainda nao chegou nem na protecao da entrada
      if(lucroPts < InpBreakevenEm) continue;

      //--- quantos degraus COMPLETOS o preco andou alem do gatilho
      int degraus = (int)MathFloor((lucroPts - InpBreakevenEm) / InpDegrauPts);

      //--- piso: a entrada protegida. Cada degrau soma por cima.
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
         if(InpLog)
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
//| LOGICA PRINCIPAL                                                 |
//| Avaliada a cada segundo, nao a cada barra: fita e evento curto.  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CANCELAR A LIMITE POR AGRESSAO CONTRA                             |
//+------------------------------------------------------------------+
double RajTickSz()
{
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return (t > 0.0) ? t : _Point;
}

//--- Volume REAL da barra, em contratos. Sem volume real nao ha com que
//--- comparar o volume da fita, que tambem vem em contratos: devolve 0 e
//--- a regra nao opina, em vez de comparar contratos com numero de
//--- negocios e produzir um fator sem significado.
double RajVolBar(const MqlRates &r)
{
   return (r.real_volume > 0) ? (double)r.real_volume : 0.0;
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

//--- Fluxo dos ultimos InpRajJanelaSeg segundos: +1 compra dominante,
//--- -1 venda dominante, 0 sem dominio.
//---
//--- Usa LerFita, a MESMA leitura que alimenta os tres sinais, para que
//--- a regra de cancelamento nao julgue a agressao por um criterio
//--- diferente do resto do robo. Com isso herda de graca o LadoAgressor
//--- de tres niveis, o teto de lote e o volume neutro no divisor.
int RajadaAgora(double &fator)
{
   fator = 0.0;

   //--- volume normal de referencia, em contratos, a mesma unidade da fita
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, InpRajMediaN, r) < InpRajMediaN) return 0;

   double soma = 0.0;
   int    nb   = 0;
   for(int k = 0; k < InpRajMediaN; k++)
   {
      double v = RajVolBar(r[k]);
      if(v > 0.0) { soma += v; nb++; }
   }
   if(nb <= 0) return 0;                        // sem volume real: nao opina

   double volJanela = (soma / nb) * InpRajJanelaSeg / 60.0;
   if(volJanela <= 0.0) return 0;

   MqlTick agora;
   if(!SymbolInfoTick(_Symbol, agora) || agora.time_msc == 0) return 0;

   TapeStats t = LerFita(InpRajJanelaSeg, agora.time_msc);
   if(!t.valido) return 0;

   //--- o neutro entra no divisor, como em todos os outros criterios
   double total = (double)(t.volCompra + t.volVenda + t.volNeutro);
   if(total <= 0.0) return 0;

   fator = total / volJanela;
   if(fator < InpRajFator) return 0;

   double dom    = InpRajDominioPct / 100.0 * total;
   double niveis = InpRajNiveis * RajTickSz();

   //--- o deslocamento so e exigido quando InpRajNiveis > 0. Com a
   //--- limitada longe da ancora, o preco executa a ordem antes de
   //--- conseguir deslocar, e exigir deslocamento aqui desliga a regra.
   if((double)t.volCompra >= dom &&
      (InpRajNiveis <= 0 ||
       t.precoMax - t.precoInicio >= niveis - RajTickSz() / 2))
      return 1;

   if((double)t.volVenda >= dom &&
      (InpRajNiveis <= 0 ||
       t.precoInicio - t.precoMin >= niveis - RajTickSz() / 2))
      return -1;

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

void OnTick()
{
   //--- O trailing vem ANTES do acelerador de 1s: gerenciar posicao aberta
   //--- e tarefa de cada tick, nao de cada segundo. Deixar aqui dentro da
   //--- trava faria o stop ficar ate 1s atrasado em relacao ao preco.
   GerenciarTrailing();
   CancelarPorRajada();

   //--- avalia no maximo uma vez por segundo
   MqlTick agora;
   if(!SymbolInfoTick(_Symbol, agora)) return;
   if(agora.time_msc == 0) return;
   if(agora.time_msc - ultimaAvaliacaoMs < 1000) return;
   ultimaAvaliacaoMs = agora.time_msc;

   //--- acumulado do dia (ou da sessao do EA)
   AtualizarAcumulado(agora.time_msc);

   //--- avanca a janela base deslizante (le apenas o segundo que entrou)
   AtualizarBase(agora.time_msc);

   //--- le a fita na janela curta (sempre, para o painel ficar vivo)
   TapeStats curta = LerFita(InpJanelaSeg, agora.time_msc);

   int s1 = 0, s2 = 0, s3 = 0;
   if(curta.valido)
   {
      s1 = SinalGrandes(curta);
      s2 = SinalVelocidade(curta);
      s3 = SinalDesequilibrio(curta);
   }

   int compras = (s1 > 0 ? 1 : 0) + (s2 > 0 ? 1 : 0) + (s3 > 0 ? 1 : 0);
   int vendas  = (s1 < 0 ? 1 : 0) + (s2 < 0 ? 1 : 0) + (s3 < 0 ? 1 : 0);
   int acum    = LadoAcumulado();

   //--- mercado indo e voltando: exige mais sinais concordando
   bool caut = ModoCauteloso();
   minSinaisAtual = caut ? MathMin(MathMax(InpChopMinSinais, InpMinSinais), sinaisAtivos)
                         : InpMinSinais;

   string estado   = "AGUARDANDO SINAL";
   bool   podeOperar = true;

   //--- portoes, do mais restritivo ao menos
   if(HasOpenPosition())
   {
      estado = "POSICAO ABERTA";
      podeOperar = false;
      if(InpUsarLimite) CancelAllOrders();
   }
   else
   {
      if(InpUsarLimite) CancelExpiredOrders();

      if(InpUsarLimite && HasPendingOrder())
      {
         estado = "ORDEM PENDENTE";
         podeOperar = false;
      }
      else if(!TimeAllowed())
      {
         estado = "FORA DO HORARIO";
         podeOperar = false;
      }
      else if(InpMinSegEntre > 0 && horaUltimaEntrada > 0 &&
              TimeCurrent() - horaUltimaEntrada < InpMinSegEntre)
      {
         estado = StringFormat("INTERVALO (%ds)",
                               InpMinSegEntre - (int)(TimeCurrent() - horaUltimaEntrada));
         podeOperar = false;
      }
      else if(!curta.valido)
      {
         estado = "FITA VAZIA";
         podeOperar = false;
      }
      else if(compras > 0 && vendas > 0)
      {
         estado = "SINAIS OPOSTOS";
         podeOperar = false;
      }
   }

   int direcao = 0;
   if(podeOperar)
   {
      if(compras >= minSinaisAtual)      direcao =  1;
      else if(vendas >= minSinaisAtual)  direcao = -1;

      int concordam = (direcao > 0) ? compras : vendas;

      //--- teria entrado sem o modo cauteloso? Registra (no maximo a cada 30s)
      //--- para dar para medir depois quantas entradas a cautela evitou.
      bool barradoCaut = (direcao == 0 && caut &&
                          MathMax(compras, vendas) >= InpMinSinais);
      if(barradoCaut && InpLog)
      {
         static datetime ultLogCaut = 0;
         if(TimeCurrent() - ultLogCaut >= 30)
         {
            ultLogCaut = TimeCurrent();
            PrintFormat("Modo cauteloso: %d sinal(is) %s, exige %d - nao entrou",
                        MathMax(compras, vendas),
                        (compras > vendas) ? "de COMPRA" : "de VENDA",
                        minSinaisAtual);
         }
      }

      if(direcao == 0)
         estado = barradoCaut ? StringFormat("CAUTELA: exige %d sinais", minSinaisAtual)
                              : "AGUARDANDO SINAL";
      else
         estado = StringFormat("ENTRANDO %s", direcao > 0 ? "COMPRADO" : "VENDIDO");

      //--- Validacao pelo acumulado. Com o filtro de tendencia fora,
      //--- este e o UNICO contexto direcional que resta no robo: o saldo
      //--- real de agressao da sessao. Um pico de 15s contra o fluxo do
      //--- dia inteiro e justamente o caso que se quer evitar.
      //--- So barra quando aponta para o lado oposto: acumulado neutro
      //--- nao impede nada (de manha ele sempre esta perto de zero).
      if(direcao != 0 && InpUsarAcumulado && acum != 0 && acum != direcao)
      {
         estado = StringFormat("CONTRA O ACUMULADO (%+d)", (int)deltaAcum);
         if(InpLog)
            PrintFormat("Sinal de %s com %d sinais barrado pelo acumulado de %d contratos",
                        direcao > 0 ? "COMPRA" : "VENDA", concordam, (int)deltaAcum);
         direcao = 0;
      }
   }

   AtualizarPainel(curta, s1, s2, s3, estado);

   //--- DIAGNOSTICO: uma linha por InpLogDiagSeg segundos dizendo onde o
   //--- fluxo parou. Serve para nao ter que adivinhar qual portao barrou.
   if(InpLogDiag && InpLogDiagSeg > 0)
   {
      static datetime ultDiag = 0;
      if(TimeCurrent() - ultDiag >= InpLogDiagSeg)
      {
         ultDiag = TimeCurrent();
         long total = curta.volCompra + curta.volVenda + curta.volNeutro;
         PrintFormat("DIAG | estado=%s | sinais C%d V%d (exige %d) | fita %d neg, vol %d | "
                     "acum=%d | pos=%s pend=%s | horario=%s | "
                     "stopsLevel=%d stop=%d alvo=%d",
                     estado, compras, vendas, minSinaisAtual,
                     curta.negocios, (int)total,
                     LadoAcumulado(),
                     HasOpenPosition() ? "sim" : "nao",
                     HasPendingOrder() ? "sim" : "nao",
                     TimeAllowed() ? "ok" : "fora",
                     (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                     InpStopPoints, InpTakePoints);
      }
   }

   if(direcao == 0) return;

   if(InpLog)
      PrintFormat(">>> ENTRADA %s | %d sinais concordando",
                  direcao > 0 ? "COMPRA" : "VENDA",
                  direcao > 0 ? compras : vendas);

   Entrar(direcao > 0);
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

   double ask = 0.0, bid = 0.0;
   if(!GetQuotes(ask, bid))
   {
      Print("Cotacao indisponivel - entrada ignorada");
      return;
   }

   double lots = CalcLots();
   bool ok = false;

   if(InpUsarLimite)
   {
      //--- de onde medir o offset
      double ancora = isLong ? ask : bid;
      string nomeAncora = "preco atual";

      if(InpAncora == ANCORA_INICIO_AGRESSAO)
      {
         double ini = InicioRajada(isLong ? 1 : -1, ultimaAvaliacaoMs);
         if(ini > 0.0)
         {
            ancora = ini;
            nomeAncora = "inicio da rajada";
         }
         else if(InpLog)
            Print("Nao identifiquei o inicio da rajada - usando o preco atual");
      }

      double preco = isLong ? ancora - InpLimitOffset * _Point
                            : ancora + InpLimitOffset * _Point;
      preco = NormalizePrice(preco);

      double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(isLong && preco >= ask - stopLevel)
      {
         if(InpLog)
            PrintFormat("Limite de compra em %.0f nao cabe abaixo do ask %.0f - ignorada",
                        preco, ask);
         return;
      }
      if(!isLong && preco <= bid + stopLevel)
      {
         if(InpLog)
            PrintFormat("Limite de venda em %.0f nao cabe acima do bid %.0f - ignorada",
                        preco, bid);
         return;
      }

      if(InpLog)
         PrintFormat("Limite %s em %.0f | ancora %.0f (%s) | offset %d",
                     isLong ? "COMPRA" : "VENDA", preco, ancora,
                     nomeAncora, InpLimitOffset);

      double stop = NormalizePrice(isLong ? preco - risk   : preco + risk);
      double tp   = NormalizePrice(isLong ? preco + reward : preco - reward);

      ok = isLong
         ? trade.BuyLimit (lots, preco, _Symbol, stop, tp, ORDER_TIME_GTC, 0, "Fita limite")
         : trade.SellLimit(lots, preco, _Symbol, stop, tp, ORDER_TIME_GTC, 0, "Fita limite");
   }
   else
   {
      double entry = isLong ? ask : bid;
      double stop  = NormalizePrice(isLong ? entry - risk   : entry + risk);
      double tp    = NormalizePrice(isLong ? entry + reward : entry - reward);

      ok = isLong ? trade.Buy (lots, _Symbol, 0.0, stop, tp, "Fita")
                  : trade.Sell(lots, _Symbol, 0.0, stop, tp, "Fita");
   }

   if(ok)
      horaUltimaEntrada = TimeCurrent();
   else
      PrintFormat("Falha na ordem: %d - %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
