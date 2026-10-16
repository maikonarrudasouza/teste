# Proteção contra agressão (Consenso_WIN v1.08 e Agressao_WIN v1.02)

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
