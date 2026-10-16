# Filtro A/D (Accumulation/Distribution)

Consenso_WIN v1.11 e Agressao_WIN v1.06.

## A regra
Lido no fechamento de cada barra:

- **A/D positivo** → o robô só abre **compra**.
- **A/D negativo** → o robô só abre **venda**.
- **A/D troca de sinal** → a ordem limite pendente do lado que deixou de valer é
  cancelada na hora.

Posição já aberta não é tocada: segue com stop, alvo e trailing normais.

## Parâmetros

| Consenso_WIN | Agressao_WIN | Padrão | O que é |
|---|---|---|---|
| AD_Usar | InpUsarAD | true | Liga o filtro |
| AD_TF | InpADTF | M1 / o do robô | Timeframe do indicador |
| AD_Vol | InpADVol | VOLUME_REAL | Volume usado, igual ao "Volumes: Real" do indicador |
| AD_Modo | InpADModo | AD_NIVEL | Nível zero ou saldo do dia |
| AD_Cancelar | InpADCancelar | true | Cancelar a limite quando cruza o zero |

## Os dois modos, e por que o segundo existe
`AD_NIVEL` é a regra que você pediu: o valor do indicador acima ou abaixo de zero.
Vale saber de uma coisa: o A/D é um acumulado desde a primeira barra que o gráfico
tem. Se o MetaTrader carregar mais ou menos histórico, o nível todo sobe ou desce
junto, e o mesmo pregão pode aparecer positivo num gráfico e negativo noutro. Não é
erro do robô, é como o indicador é calculado.

`AD_SALDO_DIA` evita isso: em vez do valor absoluto, usa a variação do A/D desde a
primeira barra do dia. Positivo quer dizer que entrou mais compra do que venda
**hoje**, independente de onde o histórico começa. Se você vir o filtro trocando de
lado sem motivo depois de recarregar o gráfico, é esse modo que resolve.

## O que foi desligado
- `M_Usar` / `InpCancelaMedia` (cancelar pela média adaptativa): **false**.
- `P_Usar` / `InpProtecao` (proteção por rajada de agressão): **false**.

O código das duas continua no arquivo, parado. É só ligar se quiser comparar.
