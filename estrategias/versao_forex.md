# Versões para forex (EURUSD)

Arquivos: `estrategias/Wyckoff20_FX.mq5` e `estrategias/TapeReading_FX.mq5`. A lógica é a mesma das versões WIN. O que mudou:

| Ponto | WIN (B3) | EURUSD (forex) |
|---|---|---|
| Volume | Real (contratos) | Volume de ticks (número de negócios), usado como aproximação |
| Delta / agressão | Ticks com lado agressor | Não existe no forex descentralizado. Filtro desligado por padrão |
| Conta | Netting | Hedging ou netting. Cada aumento de mão pode virar uma posição separada, e o robô move o stop de todas juntas |
| Lote | 1 a 3 contratos | 0,10 lote por padrão, ajustado ao mínimo e ao passo da corretora |
| Distâncias | Pontos do WIN | Pontos de 5 casas (10 pontos = 1 pip). Stop máx. 25 pips (Wyckoff) e 5 a 20 pips (Tape) |
| Horário | 09:15 a 17:00 | 10:00 a 19:00 do servidor (Londres + abertura de Nova York em servidor GMT+3). Ajuste ao fuso da sua corretora |
| Validade da ordem | Ordem do dia | GTC, cancelada pelo próprio robô após N barras |
| Perda diária | R$ | Moeda da conta |

## Limitações

- O Wyckoff 2.0 usa o perfil do "dia" que começa à meia-noite do servidor, incluindo a sessão asiática. É uma aproximação razoável, mas o volume de ticks não é o volume real negociado.
- Sem delta, os gatilhos ficam só com preço e volume de ticks, que é mais fraco que a leitura de agressão do WIN.
- O spread (normalmente 0,5 a 1,5 pip) pesa mais no Tape Reading em M1, que trabalha com stops curtos. Teste primeiro com spread real.

Teste no testador com "Cada tick baseado em ticks reais", comece em conta demo e use números mágicos diferentes das versões WIN (já vêm diferentes).

## Stop e alvo fixos

Os dois robôs de forex vêm com `InpFixo = true`: a ordem já sai com stop e alvo fixos e nada se move depois.

- Wyckoff20_FX: stop de 150 pontos (15 pips) e alvo de 300 (30 pips). A parcial e os alvos por nível de volume ficam desligados.
- TapeReading_FX: stop de 100 pontos (10 pips) e alvo de 200 (20 pips). O zero a zero, os aumentos de mão, o stop móvel, a saída por volume contra e a virada de mão ficam desligados.

Com `InpFixo = false` volta a gestão original.

## Absorção antes do gatilho (Wyckoff20_FX)

`InpExigirAbsorcao = true` por padrão. Antes da barra SOS/SOW, precisa existir pelo menos uma barra perto do nível testado com:
- volume ≥ 1,3 × média (`InpFatorAbsorcao`);
- pavio de rejeição ≥ 40% do range (`InpPavioMin`): pavio inferior na compra, superior na venda;
- fechamento na metade a favor: vendeu forte e não conseguiu fechar embaixo.

Como o forex não tem delta, a absorção é lida por volume de ticks + pavio. Se a corretora tiver delta e `InpUsarDelta` estiver ligado, exige também agressão contra nessa barra.

No TapeReading_FX, o setup de clímax já é uma absorção por definição (volume muito alto sem progresso), então não precisou de filtro novo.
