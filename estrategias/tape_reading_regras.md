# Robô Tape Reading para WIN (MQL5)

Arquivo do robô: `estrategias/TapeReading_WIN.mq5`

Fontes: capítulo 1 de *Studies in Tape Reading* (Wyckoff, 1910, tradução comentada) e *Tape Reading and Market Tactics* (Humphrey Neill, 1931). Resumo com minhas palavras.

## O que vira regra

**Do Wyckoff (cap. 1):**
- A fita mostra a tendência imediata: o robô só opera a favor dela ou na virada confirmada.
- Stop curto, sempre. Nunca fica "longe da costa".
- Quando a posição é confirmada, aumenta a mão.
- Vira a mão rápido quando a tendência muda.
- Não dorme posicionado: zera antes do fim do pregão.
- Lucro pequeno e constante, sem overtrading: limite de entradas e de perdas seguidas por dia.

**Do Neill:**
- Volume muito alto num extremo sem o preço avançar = clímax. Oferta ou demanda está sendo absorvida e o movimento tende a virar.
- O teste depois do clímax vem com volume baixo. Entra-se na ação de confirmação, não antes.
- Na tendência, recuo "morno" (volume baixo) é saudável. A retomada vem com volume. "Nunca venda um mercado morno" na alta, e o espelho na baixa.
- Volume pesado contra a posição = sair na hora.

## Setups

**1. Clímax + teste (virada)** — compra no fundo (venda no topo é o espelho):
- Barra que faz a mínima das últimas 30, com volume ≥ 2,5 × média e fechamento a pelo menos 40% do range acima da mínima (volume alto sem progresso).
- Em até 10 barras, uma barra volta a até 30 pontos da mínima, furando no máximo 20, com volume ≤ 0,8 × média (teste).
- Nenhum fechamento abaixo da mínima do clímax − 20 pontos no caminho.
- Confirmação: última barra fecha na metade de cima e a agressão não é vendedora.
- Entrada: buy stop 1 tick acima da barra. Stop abaixo da menor mínima desde o clímax + 10 pontos.

**2. Recuo morno na tendência (continuação)**:
- Tendência imediata: EMA 21 subindo e preço acima dela.
- Recuo de 2 a 8 barras desde o último topo, com volume médio ≤ 0,8 × média, sem perder a EMA.
- Barra de retomada: fecha acima da máxima da anterior, no terço superior, com volume ≥ média e delta comprador ≥ 10%.
- Entrada: buy stop 1 tick acima. Stop abaixo da mínima do recuo + 10 pontos.

## Gestão

- Stop entre 40 e 250 pontos (fora disso, não entra). Alvo final em 3R (`InpAlvoR = 0` deixa só o stop móvel).
- Em +1R: stop no zero a zero.
- Aumentos de mão em +1R e +2R (1 contrato cada). Depois de cada aumento, o stop sobe para o preço médio.
- Depois do zero a zero, o stop segue a mínima das últimas 5 barras.
- Barra com volume ≥ 2 × média fechando contra (rompendo a barra anterior) e agressão contra: sai na hora.
- Clímax no sentido oposto à posição: fecha e vira a mão.
- Limites: entradas de 09:10 a 17:15, zera às 17:50, até 6 entradas, R$ 300 de perda ou 3 perdas seguidas por dia.

## Como testar

1. Copie para `MQL5\Experts`, compile no MetaEditor (F7) e me mande o print dos erros, se houver. Não consigo compilar aqui.
2. Testador: WIN, **M1**, "Cada tick baseado em ticks reais" (sem isso não há delta).
3. Os horários são da hora do servidor. Ajuste se a corretora não estiver no horário de Brasília.
4. Os parâmetros são um ponto de partida e não foram otimizados. Comece na conta demo.

## Diferença para o robô Wyckoff 2.0

O `Wyckoff20_WIN` espera o preço chegar em níveis de volume (VAH, VAL, VWAP) no M5. Este aqui não usa níveis: lê só o esforço (volume e agressão) contra o resultado (preço) no M1, então opera mais vezes e com stop mais curto. Podem rodar juntos, com números mágicos diferentes. Na conta netting da B3, porém, os dois compartilham a mesma posição no WIN. O ideal é rodar um de cada vez ou em contas separadas.
