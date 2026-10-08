# ==============================================================
# Otimizacao de VPS Windows Server 2016 (2 GB) para MetaTrader 5
# Rodar no PowerShell COMO ADMINISTRADOR:
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\otimizar_vps_mt5.ps1
# Reiniciar a VPS ao final.
#
# O estado original dos servicos e salvo em
# C:\otimizacao_vps\servicos_antes.csv para poder desfazer.
# ==============================================================

$ErrorActionPreference = 'Continue'
$backupDir = 'C:\otimizacao_vps'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

function Info($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Aviso($msg) { Write-Host "[!!] $msg" -ForegroundColor Yellow }

# --------------------------------------------------------------
# 1) Plano de energia: Alto desempenho
# --------------------------------------------------------------
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
Info 'Plano de energia: Alto desempenho'

# --------------------------------------------------------------
# 2) Efeitos visuais: melhor desempenho (usuario atual)
# --------------------------------------------------------------
$vfx = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
New-Item -Path $vfx -Force | Out-Null
Set-ItemProperty -Path $vfx -Name VisualFXSetting -Value 2 -Type DWord
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name DragFullWindows -Value '0'
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name MenuShowDelay -Value '0'
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name MinAnimate -Value '0'
Info 'Efeitos visuais desligados'

# --------------------------------------------------------------
# 3) Nao abrir o Server Manager no logon (economiza ~100 MB)
# --------------------------------------------------------------
New-Item -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -Type DWord
Get-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
Info 'Server Manager nao abre mais no logon'

# --------------------------------------------------------------
# 4) Servicos desnecessarios para uma VPS de trading
#    (RDP, rede, Windows Update e Defender NAO sao mexidos)
# --------------------------------------------------------------
$servicos = @(
    'Spooler',              # Spooler de impressao
    'DiagTrack',            # Telemetria
    'dmwappushservice',     # Telemetria (WAP push)
    'WerSvc',               # Relatorio de erros
    'SysMain',              # Superfetch
    'WSearch',              # Windows Search (indexacao)
    'MapsBroker',           # Mapas baixados
    'lfsvc',                # Geolocalizacao
    'XblAuthManager',       # Xbox
    'XblGameSave',          # Xbox
    'WbioSrvc',             # Biometria
    'TabletInputService',   # Teclado touch / caneta
    'wisvc',                # Windows Insider
    'RemoteRegistry',       # Registro remoto (tambem melhora seguranca)
    'Audiosrv',             # Audio (VPS nao precisa de som)
    'AudioEndpointBuilder', # Audio
    'SSDPSRV',              # Descoberta SSDP
    'upnphost',             # UPnP
    'WpnService',           # Notificacoes push
    'CDPSvc',               # Plataforma de dispositivos conectados
    'PcaSvc',               # Assistente de compatibilidade
    'TrkWks',               # Rastreamento de links
    'stisvc',               # Aquisicao de imagens (scanner/camera)
    'ShellHWDetection'      # Autoplay
)

$antes = @()
foreach ($nome in $servicos) {
    $svc = Get-Service -Name $nome -ErrorAction SilentlyContinue
    if ($null -eq $svc) { continue }
    $antes += [pscustomobject]@{ Nome = $nome; StartType = $svc.StartType; Status = $svc.Status }
    try {
        Stop-Service -Name $nome -Force -ErrorAction SilentlyContinue
        Set-Service -Name $nome -StartupType Disabled -ErrorAction Stop
        Info "Servico desativado: $nome"
    } catch {
        Aviso "Nao foi possivel desativar $nome ($($_.Exception.Message))"
    }
}
if (-not (Test-Path "$backupDir\servicos_antes.csv")) {
    $antes | Export-Csv -Path "$backupDir\servicos_antes.csv" -NoTypeInformation -Encoding UTF8
}

# --------------------------------------------------------------
# 5) Tarefas agendadas de telemetria / desfragmentacao
# --------------------------------------------------------------
$tarefas = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\Defrag\ScheduledDefrag',
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
    '\Microsoft\Windows\Maps\MapsUpdateTask',
    '\Microsoft\Windows\Maps\MapsToastTask'
)
foreach ($t in $tarefas) {
    $path = (Split-Path $t -Parent) + '\'
    $name = Split-Path $t -Leaf
    $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
    if ($task) { $task | Disable-ScheduledTask | Out-Null; Info "Tarefa desativada: $name" }
}

# --------------------------------------------------------------
# 6) Windows Update: nao reiniciar sozinho no meio do pregao
#    (avisa e baixa, mas so instala/reinicia quando voce mandar)
# --------------------------------------------------------------
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 0 -Type DWord
Set-ItemProperty -Path $au -Name AUOptions -Value 3 -Type DWord        # baixa e avisa
Set-ItemProperty -Path $au -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
Info 'Windows Update: baixa e avisa, sem reinicio automatico'

# --------------------------------------------------------------
# 7) RDP: sessao desconectada NUNCA e encerrada
#    (fechar o RDP no X mantem o MT5 rodando)
# --------------------------------------------------------------
$ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
New-Item -Path $ts -Force | Out-Null
Set-ItemProperty -Path $ts -Name MaxDisconnectionTime -Value 0 -Type DWord
Set-ItemProperty -Path $ts -Name MaxIdleTime -Value 0 -Type DWord
Set-ItemProperty -Path $ts -Name fResetBroken -Value 0 -Type DWord
Info 'RDP: sessoes desconectadas ficam abertas'

# --------------------------------------------------------------
# 8) Defender: excluir o MetaTrader da varredura em tempo real
#    (o Defender continua ligado para o resto do sistema)
# --------------------------------------------------------------
if (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
    $pastas = @(
        "$env:ProgramFiles\MetaTrader 5",
        "$env:APPDATA\MetaQuotes"
    )
    # Inclui pastas de corretoras (ex.: C:\Program Files\XP MetaTrader 5)
    Get-ChildItem $env:ProgramFiles -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*MetaTrader*' } |
        ForEach-Object { $pastas += $_.FullName }
    foreach ($p in ($pastas | Select-Object -Unique)) {
        Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
    }
    Add-MpPreference -ExclusionProcess 'terminal64.exe','metatester64.exe','metaeditor64.exe' -ErrorAction SilentlyContinue
    Set-MpPreference -ScanAvgCPULoadFactor 20 -ErrorAction SilentlyContinue
    Info 'Defender: MetaTrader excluido da varredura, CPU da varredura limitada a 20%'
}

# --------------------------------------------------------------
# 9) Arquivo de paginacao fixo (4 GB) - evita travadas por
#    redimensionamento quando a RAM de 2 GB enche
# --------------------------------------------------------------
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
    }
    $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'C:*' }
    if ($null -eq $pf) {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'C:\pagefile.sys' } | Out-Null
        $pf = Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -like 'C:*' }
    }
    Set-CimInstance -InputObject $pf -Property @{ InitialSize = 4096; MaximumSize = 4096 }
    Info 'Paginacao fixa em 4096 MB (vale apos reiniciar)'
} catch {
    Aviso "Nao foi possivel ajustar a paginacao: $($_.Exception.Message)"
}

# --------------------------------------------------------------
# 10) Limpeza de arquivos temporarios
# --------------------------------------------------------------
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
Info 'Temporarios limpos'

Write-Host ''
Write-Host "Backup dos servicos: $backupDir\servicos_antes.csv" -ForegroundColor Cyan
Write-Host 'Concluido. A VPS precisa reiniciar para aplicar tudo.' -ForegroundColor Cyan
$resp = Read-Host 'Reiniciar agora? (S/N)'
if ($resp -match '^[sS]') { Restart-Computer -Force }
