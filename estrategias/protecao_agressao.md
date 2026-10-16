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
