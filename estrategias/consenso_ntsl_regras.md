# Consenso_WIN no ProfitChart (NTSL)

Arquivo: `estrategias/Consenso_WIN.ntsl`. Conversão do `Consenso_WIN.mq5` (MT5) para NTSL.

## O que mudou na conversão

| MT5 | NTSL | Por quê |
|---|---|---|
| 4 votos (Delta, Fita, VP, Agressão) | 3 votos (Agressão, Delta, VP) | O NTSL não dá acesso negócio a negócio do Times & Trades, só o volume de agressão por barra. A Fita, que lia a cada segundo, foi absorvida pelo Delta. |
| Consenso conferido a cada segundo (`InpTempoReal`) | Só no fechamento do candle | O NTSL executa por candle. |
| Trailing stop de 1 tick | Não tem | Sem reavaliação intrabar não dá para acompanhar o preço. |
| Ordem limite com validade de N barras | Mesma ideia, reenviando | No NTSL a ordem morre no fim do candle, então o robô reenvia a mesma limite a cada candle até vencer o prazo. |
| Painel no gráfico | `Plot(compras - vendas)` | O placar vira uma linha: +1 a +3 é compra, -1 a -3 é venda. |

## Votos

1. **Agressão:** volume agredido da barra ≥ 2× o volume médio de 30 barras, com 70% de um lado e o candle fechando a favor.
2. **Delta:** saldo de agressão acumulado das últimas 10 barras ≥ 200 contratos a favor.
3. **VP:** fechamento acima da VAH + 20 pontos (ou abaixo da VAL − 20). A área de valor sai de um perfil de 120 barras em 50 faixas, com 70% do volume.

Cada voto vale 5 barras. Com 2 votos do mesmo lado, manda limite a 200 pontos do fechamento, válida 3 barras. Stop 120, gain 75, zera às 17:50.

## Antes de rodar

- Os votos de Agressão e Delta usam `AgressionVolBuy`/`AgressionVolSell`, que **exigem Profit Pro com plugin TR, Ultra ou módulo Scalper**. Sem isso, deixe `UsarAgressao` e `UsarDelta` como `False`: o robô passa a operar só pela área de valor.
- O perfil de volume roda um laço de 120 barras × 50 faixas a cada candle. Se pesar, baixe `VPBarras` ou `VPFaixas`.
- No backtest use o modo **Tick a Tick**.
- Não compilei este arquivo: o NTSL só compila dentro do ProfitChart. Se der erro, me mande o print da mensagem.
