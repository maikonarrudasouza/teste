# Robô Wyckoff 2.0 para WIN (MQL5)

Arquivo do robô: `estrategias/Wyckoff20_WIN.mq5`

## O que tirei do livro (resumo com minhas palavras)

O método do livro tem quatro passos, e o robô segue a mesma ordem:

1. **Contexto.** O mercado está em equilíbrio (dentro da área de valor) ou em desequilíbrio (aceito fora dela)? Em equilíbrio, opera os extremos. Em desequilíbrio, só a favor e no recuo.
2. **Onde.** A entrada só é procurada em níveis operacionais: VAH, VAL e VPOC da sessão anterior, VWAP e áreas de alto/baixo volume. Fora deles, o fluxo de ordens é ruído.
3. **Gatilho.** Uma barra de intenção (SOS na compra, SOW na venda): range amplo, fechamento no terço extremo e volume alto. Pelo fluxo, é a "iniciativa": agressão a favor que move o preço. Antes dela pode haver "absorção": agressão forte contra que não consegue mover o preço.
4. **Gestão.** Entrada com ordem stop além da barra de gatilho (filtra barras que viram logo depois). Stop do outro lado da barra ou do nível. Alvos nas áreas de alto volume à frente (VPOC, extremo oposto da área de valor, VPOCs "nus" de sessões antigas). No primeiro nível relevante, realiza parcial e protege.

Os quatro princípios de área de valor que viraram regras:

| Princípio | Situação | O que o robô faz |
|---|---|---|
| Faixa | Preço dentro da VA anterior | Compra no teste da VAL, vende no teste da VAH. Alvo 1 no VPOC, alvo 2 no extremo oposto |
| Reversão (regra dos 80%) | Saiu da VA e voltou para dentro | Mesmo setup da faixa, já que o regime volta a ser "dentro" |
| Continuação | Aceito fora da VA | Compra no reteste da VAH por cima (ou vende no da VAL por baixo) |
| Reversão falha | Voltou para a VA mas foi rejeitado no VPOC | Coberto pela parcial + zero a zero no primeiro alvo |

## Regras objetivas

**Regime do dia** (barras do tempo gráfico do gatilho, M5 por padrão):
- 3 fechamentos seguidos acima da VAH anterior = **aceito acima**.
- 3 fechamentos seguidos abaixo da VAL = **aceito abaixo**.
- 3 fechamentos seguidos dentro = **dentro**.
- Antes disso, não opera.

**Teste do nível:** a mínima (compra) chega a até 40 pontos do nível, podendo furar até 150 pontos (o "spring" ou "shakeout"). O gatilho precisa aparecer em até 3 barras e fechar de volta do lado certo do nível.

**Barra de gatilho (SOS/SOW):**
- range ≥ 1,2 × range médio das últimas 20 barras;
- volume ≥ 1,3 × volume médio;
- fechamento no terço superior (compra) ou inferior (venda);
- delta de agressão ≥ 10% do volume agredido a favor. Se a corretora não mandar o lado agressor nos ticks, o filtro desliga sozinho e avisa no log.

**Entrada:** buy stop 1 tick acima da máxima do gatilho (sell stop 1 tick abaixo da mínima). A ordem vale 2 barras. Se o preço já passou da entrada, não persegue.

**Stop:** do outro lado da barra de gatilho + 10 pontos (ou do outro lado do nível, com `InpModoStop = STOP_NIVEL`). Se passar de 400 pontos, não entra.

**Alvos:** próximos níveis à frente (VPOC, VAH/VAL, máxima/mínima, VWAP e VPOCs nus), ignorando os que estão a menos de 0,5R. Alvo 1 = parcial de 50% e stop no zero a zero. Alvo 2 = saída final. Se o alvo 2 der menos de 1,5R, não entra. Sem nível à frente: 1R e 2R.

**Limites:** entradas entre 09:15 e 17:00, zera às 17:50, no máximo 3 entradas e R$ 300 de perda por dia.

## Sobre HFT

HFT de verdade não é possível com MT5 numa VPS de varejo. Uma ordem leva milissegundos passando pela corretora, enquanto quem faz HFT na B3 fica em colocation e reage em microssegundos. Disputar fila ou arbitragem contra eles é perder.

O que o robô faz para ser rápido de forma realista:
- a decisão é tomada no fechamento da barra, sem depender de velocidade;
- a ordem stop fica na bolsa, então a execução não espera o robô;
- entre uma barra e outra, o `OnTick` só compara preço com alvo, o que é leve para a VPS de 2 GB.

## Como testar

1. Copie `Wyckoff20_WIN.mq5` para `MQL5\Experts`, abra no MetaEditor e compile (F7). Eu não consigo compilar aqui, então se der erro me mande o print da aba "Erros".
2. No Testador de Estratégia, use o **WIN contínuo ou o vencimento atual**, M5, modelagem **"Cada tick baseado em ticks reais"** (sem isso não há delta), de preferência com 3 meses ou mais.
3. Confira no gráfico visual se as linhas VAH (vermelha), VAL (azul), VPOC (dourada), VWAP (roxa) e VPOCs nus (cinza) batem com o seu Volume Profile do Profit.
4. Confira o fuso: os horários são da hora do servidor da corretora. Se o servidor não estiver em horário de Brasília, ajuste `InpInicio`, `InpFimEntradas` e `InpZerar`.
5. Na VPS com "máx. barras = 5000", cabem cerca de 8 pregões em M1, o que é suficiente para o perfil anterior e 5 VPOCs nus. Se aumentar `InpSessoesNaked`, suba esse limite.

Comece na conta demo. Os parâmetros padrão vêm do livro (terço de fechamento, área de valor 70%) e de valores típicos do WIN, mas ainda não foram otimizados.

## Filtro de direção da VWAP (padrão ligado)

Só compra com a VWAP do dia subindo e só vende com ela caindo (VWAP atual menos a de 6 barras atrás, `InpVwapBarras`). No início do pregão, até haver 6 barras, não opera. Desligue com `InpFiltroVWAP = false`.

## Padrões atuais (versão de outubro)

- Tempo gráfico M1, 1 contrato, sem aumento de mão.
- Entrada por ordem limitada 250 pontos melhor que o fechamento do sinal, válida por 5 barras (`InpOffsetLimite`, `InpValidadeOrdem`). `InpTipoOrdem = ENTRADA_STOP` volta à entrada antiga.
- Stop fixo de 150 pontos e alvo fixo de 500 pontos a partir do preço de entrada (`InpFixo = true`; sem parcial).
- Trailing stop: depois de 50 pontos a favor, o stop fica 5 pontos (1 tick) atrás do preço e só anda a favor (`InpTrailAtivar`, `InpTrailDist`).
- Zera às 17:50 (`InpZerarFimDia`).
