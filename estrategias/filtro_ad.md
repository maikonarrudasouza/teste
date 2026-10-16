# Filtro A/D (Accumulation/Distribution)

Consenso_WIN v1.12 e Agressao_WIN v1.07.

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

## O que foi retirado
A regra de cancelar pela média adaptativa e a proteção por rajada de agressão
foram removidas do código dos dois robôs. Se um dia quiser alguma delas de volta,
está no histórico do repositório (commits `32c2e0c` e `e327199`).

O filtro de tendência por média (`InpUsarFiltroTend` no Agressão, `D_FiltroTend` e
`F_FiltroTend` no Consenso) continua existindo: é outra coisa, e não foi mexido.

# Cancelar a limite por agressão contra (opcional)

Consenso_WIN v1.13 e Agressao_WIN v1.08. Vem **desligada**.

Enquanto existe ordem limite pendente, o robô lê uma vez por segundo os últimos
10 segundos de negócios. Se vier uma rajada **contra o lado da ordem** — volume da
janela acima do normal, dominada de um lado e com o preço andando naquele sentido —
a ordem é cancelada. Só isso:

- não mexe em posição aberta;
- não tem pausa; o único bloqueio é não recolocar a mesma ordem naquela barra.

A ideia é que cancelar ordem pendente é barato: nada foi aberto, nada foi realizado,
e o sinal volta na barra seguinte se ainda fizer sentido. O pior caso é perder uma
entrada.

| Consenso_WIN | Agressao_WIN | Padrão |
|---|---|---|
| X_Usar | InpUsarRajada | false |
| X_JanelaSeg | InpRajJanelaSeg | 10 s |
| X_FatorVolume | InpRajFator | 3.0 |
| X_DominioPct | InpRajDominioPct | 75% |
| X_NiveisMin | InpRajNiveis | 22 (110 pontos) |

Ela convive com o filtro A/D sem conflito: o A/D decide de que lado operar, antes de
a ordem existir; a rajada decide se aquela ordem específica ainda deve ser executada.
No painel do Consenso, quando ligada, a linha do A/D passa a mostrar também a rajada
atual em "x o volume normal".
