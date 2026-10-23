# Robô de Agressão para WIN (MQL5)

Arquivo: `estrategias/Agressao_WIN.mq5`. Base: "Guia do Tape Reading" (Wilson Neto), capítulo 9, Agressões.

## Entrada
1. Ao fechar cada barra M1, o robô lê os negócios da barra (Times & Trades) com o lado agressor de cada um.
2. Procura uma janela de 10 segundos em que:
   - o preço anda pelo menos 3 níveis (15 pontos) a partir do primeiro negócio;
   - o volume agredido é pelo menos 3x o volume normal de 10 segundos (média das últimas 30 barras);
   - pelo menos 70% desse volume é do lado da agressão.
3. A barra precisa fechar acima do preço onde a agressão começou (abaixo, na venda).
4. Coloca compra limitada 100 pontos abaixo do fechamento (venda limitada 100 acima), válida por 2 barras.

## Gestão
- Stop 150 pontos, gain 500 pontos.
- Trailing: depois de +50 pontos, o stop fica 5 pontos (1 tick) atrás do preço e só anda a favor.
- 1 contrato, uma posição por vez, sem aumento de mão.
- Entradas das 09:15 às 17:15, zera às 17:50, até 6 entradas, R$ 300 de perda ou 3 perdas seguidas por dia.

## Teste
Backtest em M1 com "Cada tick baseado em ticks reais", senão não há Times & Trades. Se a corretora não mandar o lado agressor, o robô usa a regra do tick (negócio acima do anterior = compra) e avisa no log.
