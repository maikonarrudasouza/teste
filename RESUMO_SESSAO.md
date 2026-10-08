# Resumo da sessão — 08/10/2026

## 1. Robô "Tape Reader - Fita WIN" (ProfitChart / NTSL)

Arquivo: `estrategias/fita_win_corrigido.ntsl`

**Por que os 3 sinais não acionavam**
- `MinNegociosGrandes` e `MinNegociosDeseq` (20) eram maiores que a janela de leitura (15 segundos), então Grandes e Desequilíbrio nunca podiam acionar. Agora o mínimo é limitado ao tamanho da janela.
- A Velocidade comparava segundos ativos com segundos ativos. No WIN quase todo segundo tem negócio, então o fator ficava em ~1. Agora compara volume agredido por segundo.
- O volume "neutro" misturava `Volume` (financeiro, R$) com agressão (contratos), o que derrubava os percentuais. O total agora é compra + venda agredida.
- `TetoDeLote` descartava justamente as rajadas. O padrão passou a ser 0 (desligado).

**Desempenho:** a janela base e o delta passaram a ser lidos em candles de 1 minuto (cerca de 10 leituras em vez de 600 de 1s), o que resolveu o aviso de atraso.

**Ordens**
- No NTSL a ordem só vale 1 candle, então a limitada agora é reenviada até vencer.
- Stop, gain e trailing agora são enviados de verdade (`SellToCoverStop/Limit`, `BuyToCoverStop/Limit`, com `FolgaStop`).
- O tempo usa a hora do candle (não `CurrentTime`) e zera a cada dia.
- A entrada é registrada antes do trailing.

**Padrões atuais (gráfico de 10s):** `JanelaVelocS` 11, `MinNegocios` 6, `VolMinDeseq` 250, `VolLiqMinGrandes` 150, `OffsetOrdem` 0. `MinNegociosVeloc` agora conta **minutos**.

## 2. Robô "Limite Contra a Agressão" (ProfitChart / NTSL)

Arquivo: `estrategias/limite_contra_agressao_corrigido.ntsl`

- `AtualizarOrdem(true)`: ordem em escada. A compra começa em Low − `DistanciaPontos` e desce `PassoPontos` (50) a cada candle; a venda é o espelho, em High + distância. Com `false`, volta ao comportamento original (Close ± distância, só no candle do sinal).
- A ordem fica viva até executar, até vir um sinal contrário ou até a tendência virar (fechamento cruzar a média 21 contra a ordem).
- `ReiniciarNoSinal(0)`: um sinal repetido no mesmo lado não mexe na escada. Com 1, reinicia em Low/High ± distância, que era o que fazia a ordem andar só 10 pontos.
- Saídas reativadas: stop e gain com `Round2Fraction` e `FolgaStop`.

**Não confirmado sem compilar:** input booleano `AtualizarOrdem(true)` (alternativa: `1`/`0`) e `SellToCoverStop`/`BuyToCoverStop` com dois preços (alternativa: só o preço do stop).

## 3. VPS Windows Server 2016 (2 GB) para MetaTrader 5

Arquivos: `vps/otimizar_vps_mt5.bat` (duplo clique), `vps/otimizar_vps_mt5.ps1`, `vps/guia_vps_mt5.md`

- O script desliga serviços inúteis e efeitos visuais, impede reinício automático do Windows Update, mantém a sessão RDP aberta ao desconectar, fixa a paginação em 4 GB e exclui o MT5 do Defender.
- O Defender foi removido manualmente (`Uninstall-WindowsFeature Windows-Defender`), economizando ~170 MB. Sem antivírus: não navegar na VPS e usar senha forte.
- No MT5: máx. barras = 5000, notícias e sons desligados, Observação do Mercado só com os ativos dos robôs, MetaEditor fechado após compilar.

**Memória medida:** 39% → 27% (Windows sozinho) → 34–35% com o MT5 aberto → 42% logado na corretora, sem gráficos.

**Próximo passo:** colocar os 3 robôs e observar o pico de memória durante o pregão. A meta é ficar abaixo de 70%.
