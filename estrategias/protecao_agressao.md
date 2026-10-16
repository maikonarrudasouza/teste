# Cancelar a limite pela média (regra principal)

No fechamento de cada barra, se o candle fechou do lado contrário da ordem limite
pendente, a ordem é cancelada:

- candle fechou **acima** da média e a ordem é de **venda** → cancela;
- candle fechou **abaixo** da média e a ordem é de **compra** → cancela.

Enquanto o último candle fechado estiver desse lado, o robô também **não manda**
ordem nova daquele lado. Sem isso o consenso recolocaria a mesma venda no tick
seguinte e o cancelamento não valeria de nada.

A regra só mexe em ordem pendente. Posição aberta não é tocada: ela segue com
stop, alvo e trailing normais.

| Consenso_WIN | Agressao_WIN | Padrão | O que é |
|---|---|---|---|
| M_Usar | InpCancelaMedia | true | Liga a regra |
| M_TF | InpMCTF | M1 / o do robô | Timeframe do candle e da média |
| M_Tipo | InpMCTipo | MEDIA_ADAPTATIVA | AMA ou média comum |
| M_Preco | InpMCPreco | PRICE_WEIGHTED | HLCC/4, como na janela do MetaTrader |
| M_AMA_Per | InpMCAMAPeriodo | 1 | AMA: período |
| M_AMA_Rap | InpMCAMARapida | 6 | AMA: EMA rápida |
| M_AMA_Len | InpMCAMALenta | 30 | AMA: EMA lenta |
| M_Periodo / M_Metodo | InpMCPeriodo / InpMCMetodo | 50 / EMA | Usados só com MEDIA_COMUM |
| M_Folga | InpMCFolga | 0 | Pontos além da média para valer o cancelamento |

Se a média ficar colada demais no preço e cancelar ordem boa, aumente a folga
(0 para 20 ou 30 pontos) em vez de mexer na AMA.

# Proteção contra agressão (opcional, DESLIGADA por padrão)

Esta parte não é a regra da média acima. Ela existe no código mas vem desligada
(`P_Usar = false`, `InpProtecao = false`); ligue só se quiser testar.

## O que ela faz
A cada segundo, enquanto existe ordem limite pendente ou posição aberta, o robô lê
os negócios dos últimos N segundos direto do Times & Trades e mede três coisas:

1. **Volume** da janela contra o volume normal (média das últimas 30 barras,
   proporcional ao tamanho da janela).
2. **Domínio**: quanto desse volume foi agredido de um só lado.
3. **Deslocamento**: quantos níveis (ticks) o preço andou naquele mesmo sentido.

Se os três critérios baterem e a agressão for **contra a mão do robô**, ele:

- **cancela a ordem limite pendente** (ela ia ser executada justo dentro do movimento contra), e/ou
- **zera a posição aberta**, e
- entra em **pausa**: não manda ordem nova durante InpProtPausaSeg / P_PausaSeg segundos.

## Parâmetros

| Consenso_WIN | Agressao_WIN | Padrão | O que é |
|---|---|---|---|
| P_Usar | InpProtecao | true | Liga a proteção |
| P_JanelaSeg | InpProtJanelaSeg | 10 | Janela de leitura, em segundos |
| P_FatorVolume | InpProtFator | 3.0 | Volume da janela ≥ fator × volume normal |
| P_DominioPct | InpProtDominioPct | 75 | % do volume agredido de um lado |
| P_NiveisMin | InpProtNiveis | 3 | Níveis (ticks) que o preço andou contra |
| P_CancelarLimite | InpProtCancelar | true | Cancela a limite pendente |
| P_ZerarPosicao | InpProtZerar | true | Zera a posição |
| P_SoNoPrejuizo | InpProtSoNoPrejuizo | false | Zera só se estiver perdendo |
| P_PausaSeg | InpProtPausaSeg | 120 | Segundos sem nova ordem depois de proteger |
| P_SoAvisar | InpProtSoAvisar | false | TESTE: só escreve no log, não cancela nem zera |

## Modo de teste: medir antes de confiar
Ligue `P_SoAvisar` (Consenso) ou `InpProtSoAvisar` (Agressão) e deixe um pregão rodando.
A proteção lê a fita e escreve no log o que **faria** ("SÓ AVISO ... ZERARIA / CANCELARIA"),
sem mexer em ordem nem em posição. Conte as linhas no fim do dia; o painel do Consenso
mostra o total do dia separado entre limite e posição. Com esse número você escolhe o
fator de volume em cima dos seus dados em vez de estimativa.

## Como calibrar
- **Protegeu demais / saiu de operações boas**: aumente o fator (3.0 → 4.0) ou o
  domínio (75 → 85), ou ligue P_SoNoPrejuizo para não abortar trade que já está ganhando.
- **Não protegeu quando travou**: baixe o fator (3.0 → 2.0) ou o domínio (75 → 65),
  e aumente a janela (10 → 15 s) para pegar agressão mais espalhada.
- **Entrou de novo logo depois e tomou outra**: aumente a pausa (120 → 300 s).

## Onde ver
No painel do Consenso há uma linha nova: mostra a agressão atual em "x o volume
normal", o gatilho, e "PROTEGIDO - sem ordem nova por X s" durante a pausa.
No Agressao_WIN tudo sai no log do Expert ("PROTEÇÃO: ...").

## Observação
A leitura depende de o símbolo entregar o lado agressor nos ticks. Sem isso o robô
cai na regra do tick (subiu = compra, caiu = venda), que é mais grosseira mas
funciona para medir volume e deslocamento.

# Filtro de tendência com média adaptativa (AMA)

Os dois robôs aceitam agora duas médias no filtro de tendência:

- `MEDIA_COMUM`: média normal (EMA 50 por padrão, no fechamento). É o padrão.
- `MEDIA_ADAPTATIVA`: a AMA/KAMA, com os mesmos campos da janela do MetaTrader —
  período, EMA rápida, EMA lenta e preço aplicado. Os padrões já vêm 1 / 6 / 30
  com Weighted Close (HLCC/4).

| Consenso_WIN | Agressao_WIN | Padrão |
|---|---|---|
| T_Tipo | InpMATipo | MEDIA_COMUM |
| T_Preco | InpMAPreco | PRICE_WEIGHTED (só vale para a AMA) |
| T_AMA_Per | InpAMAPeriodo | 1 |
| T_AMA_Rap | InpAMARapida | 6 |
| T_AMA_Len | InpAMALenta | 30 |
| T_TF | InpTFTendencia | M5 |
| T_DistMin | InpMADistMin | 25 pontos |

A média comum continua usando o fechamento, para não mudar o comportamento de
quem já estava rodando com ela.

Cuidado com o período 1: a AMA assim fica muito colada no preço, então ela filtra
pouco. Ela barra entrada contra o movimento imediato, não contra a tendência do dia.
Se quiser que ela segure mais, aumente a zona neutra (25 para 50 pontos) ou suba o
tempo gráfico do filtro.
