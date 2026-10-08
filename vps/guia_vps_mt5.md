# VPS 2 GB com MetaTrader 5: o que otimizar

Ordem recomendada: rodar o script do Windows, reiniciar, depois ajustar o MT5. O maior ganho de RAM costuma vir do MT5, não do Windows.

## 1. Windows (script)

Arquivo: `otimizar_vps_mt5.ps1`. Copie para a VPS, abra o PowerShell **como Administrador** na pasta do arquivo e rode:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\otimizar_vps_mt5.ps1
Restart-Computer
```

O que ele faz:

| Ajuste | Por quê |
|---|---|
| Plano de energia Alto desempenho | CPU não fica economizando no meio do pregão |
| Efeitos visuais desligados | Menos CPU/RAM no RDP |
| Server Manager não abre no logon | Economiza uns 100 MB |
| Desativa ~24 serviços inúteis (impressão, telemetria, Xbox, áudio, busca, etc.) | RAM e CPU de fundo |
| Desativa tarefas de telemetria e desfragmentação | Picos de CPU/disco aleatórios |
| Windows Update baixa e avisa, sem reinício automático | Evita a VPS reiniciar sozinha com posição aberta |
| Sessão RDP desconectada nunca é encerrada | Fechar o RDP no X mantém o MT5 rodando |
| Defender ignora as pastas e processos do MetaTrader | O antivírus não varre cada tick/arquivo do MT5 |
| Paginação fixa de 4 GB | Evita travadas quando a RAM de 2 GB enche |

Não mexe em RDP, rede, firewall nem no Windows Update em si.

**Para desfazer um serviço:** `Set-Service -Name Spooler -StartupType Manual`. O estado original fica em `C:\otimizacao_vps\servicos_antes.csv`.

## 2. MetaTrader 5 (maior ganho)

**Ferramentas > Opções > Gráficos**
- **Máx. barras no gráfico: 5000** (o padrão "ilimitado" é o que mais consome RAM). Se o robô precisa de mais histórico, use 10000.
- Desmarque "Mostrar níveis de negociação" se não precisar ver.

**Ferramentas > Opções > Servidor**
- Desmarque **Habilitar notícias**.

**Ferramentas > Opções > Eventos**
- Desmarque **Habilitar** (sons).

**Ferramentas > Opções > Comunidade / Sinais**
- Não logar na comunidade e desmarcar sinais.

**Observação do Mercado (Ctrl+M)**
- Botão direito > **Ocultar tudo** e deixe só os ativos que o robô usa (ex.: WIN, WDO).

**Gráficos**
- Feche todos os gráficos que não têm robô. Um gráfico por robô.
- Tire indicadores que não são usados pelo robô.
- Use um tempo gráfico que o robô realmente precisa. Gráfico de ticks ou de segundos consome bem mais.

**Testador de estratégia**
- Não faça backtest/otimização na VPS. Em **Testador > Agentes**, desative os agentes locais.

**Janela**
- Deixe o MT5 **minimizado** quando sair do RDP. Ele para de redesenhar gráficos e usa menos CPU.

## 3. Rotina

- **Sair do RDP:** feche no **X** (desconectar). Nunca use "Sair/Sign out", que fecha o MT5.
- **MT5 abrindo sozinho após reinício:** coloque um atalho do `terminal64.exe` em `shell:startup` (Win+R > `shell:startup`). Para funcionar sem você logar, configure logon automático com o **Sysinternals Autologon** (guarda a senha criptografada).
- **Atualizações do Windows:** instale e reinicie manualmente no fim de semana.
- **Conferir:** no Gerenciador de Tarefas, com o MT5 rodando, o uso de memória deve ficar bem abaixo de 2 GB. Se passar de ~1,6 GB, reduza as barras por gráfico ou o número de gráficos.

## 4. Na conexão RDP (seu PC)

No `mstsc` > Mostrar opções > **Exibição**: cores **16 bits**. Em **Experiência**: escolha **Modem (56 kbps)** para desligar papel de parede e efeitos. A sessão fica mais leve para a VPS.
