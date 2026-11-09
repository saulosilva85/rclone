<# : cabecalho do cmd; para o PowerShell este bloco e comentario
@echo off
set "BACKUP_OCI_ARQUIVO=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$b = [IO.File]::ReadAllBytes($env:BACKUP_OCI_ARQUIVO); try { $t = (New-Object Text.UTF8Encoding $false, $true).GetString($b) } catch { $t = [Text.Encoding]::Default.GetString($b) }; & ([ScriptBlock]::Create($t.TrimStart([char]0xFEFF)))"
pause & exit /b %errorlevel%
#>
# =========================== EDITE SO ESTE BLOCO ============================
# Backup OCI da Clinica Pierro: botao direito neste arquivo > Executar como administrador.
# Ja instalado, abre um menu (setas ou numeros): ver o backup, rodar agora, restaurar e
# atualizar. A chave de acesso nao fica neste arquivo: o instalador pede na primeira vez.

# Pastas a copiar. Pode deixar como esta: o instalador mostra as pastas compartilhadas
# deste computador para escolher (setas, Espaco, Enter) e grava a escolha aqui. Para
# digitar: caminho completo, uma por linha, virgula entre elas; pasta de rede
# (\\servidor\pasta) nao funciona.
$Pastas = @(
    "D:\Exemplo\Pasta 1",
    "E:\Exemplo\Pasta 2"
)

# Horario do backup diario (HH:mm); o instalador pergunta e grava aqui. Com o computador
# desligado, roda quando ligar.
$Horario = "22:00"

# Limite de banda (ex.: "08:00,2M 19:00,off"). Vazio = sem limite.
$LimiteBanda = ""

# Nome deste computador no backup. Vazio = nome do Windows.
$Servidor = ""
# ============================================================================


# ----------------------- Daqui para baixo, nao alterar ------------------------
$Backup = $args -contains "-Backup"
$Exclusoes = @('~$*', 'Thumbs.db', '*.tmp')
$RetencaoLogsDias = 30
$EsperaRedeMinutos = 15
$IntervaloNovaTentativaMinutos = 60
$DiasSemBackupParaAlerta = 3
$Bucket = "backup-clinica-pierro"
$Regiao = "sa-vinhedo-1"
$EndpointFqdn = "pierro-axqhutvmc1ov.private.compat.objectstorage.sa-vinhedo-1.oci.customer-oci.com"
$EndpointIp = "172.30.10.10"
$EndpointInternet = "axqhutvmc1ov.compat.objectstorage.sa-vinhedo-1.oraclecloud.com"
$Destino = "C:\Backup-OCI"
$NomeTarefa = "Backup OCI"
# rclone.exe windows-amd64, baixado na instalacao. Antes do Windows 10/Server 2016: v1.63.1.
$RcloneSite = "https://downloads.rclone.org"
$RcloneAtual = @{ Versao = "v1.75.2"; Sha256 = "41EAB3E118D264920B62C3327966C5ECE0DC4DD715EE617D9E30450D8EAD95A4" }
$RcloneLegado = @{ Versao = "v1.63.1"; Sha256 = "AAA647327BA5B855BEDEA8E889B3FAFDC05A6CA75D1CFD98869432006D6FECC9" }

$ErrorActionPreference = "Stop"
if (-not $Servidor) { $Servidor = $env:COMPUTERNAME.ToLower() -replace "[^a-z0-9-]", "-" }
# Pelo .cmd o caminho vem de BACKUP_OCI_ARQUIVO; pela tarefa (-File), do PowerShell.
$Script = $MyInvocation.MyCommand.Path
if (-not $Script) { $Script = $env:BACKUP_OCI_ARQUIVO }
$Base = Split-Path -Parent $Script
$RaizBucket = "oci:$Bucket"
$Remoto = "$RaizBucket/$Servidor"

# A chave chega ao rclone so por variavel de ambiente, sem rclone.conf.
function Set-RemotoOci([string]$Endpoint, $Chave) {
    $env:RCLONE_CONFIG_OCI_TYPE = "s3"
    $env:RCLONE_CONFIG_OCI_PROVIDER = "Other"
    $env:RCLONE_CONFIG_OCI_ACCESS_KEY_ID = $Chave.AccessKey
    $env:RCLONE_CONFIG_OCI_SECRET_ACCESS_KEY = $Chave.SecretKey
    $env:RCLONE_CONFIG_OCI_REGION = $Regiao
    $env:RCLONE_CONFIG_OCI_ENDPOINT = "https://$Endpoint"
    $env:RCLONE_CONFIG_OCI_FORCE_PATH_STYLE = "true"
    $env:RCLONE_CONFIG_OCI_NO_CHECK_BUCKET = "true"
}

function Write-Etapa([int]$Numero, [string]$Texto) {
    Write-Host ""
    Write-Host ("[{0}/8] {1}" -f $Numero, $Texto) -ForegroundColor Cyan
}

# Toda pergunta passa por aqui; os testes automaticos respondem no lugar do tecnico.
function Read-Resposta([string]$Pergunta) { return ([string](Read-Host $Pergunta)).Trim() }

function Stop-Instalacao([string]$Texto) {
    Write-Host ""
    Write-Host "ERRO: $Texto" -ForegroundColor Red
    & cmd.exe /c "schtasks /query /tn `"$NomeTarefa`" >nul 2>&1"
    if ($LASTEXITCODE -eq 0) { $agenda = "O agendamento que ja existia continua ativo." } else { $agenda = "Nada foi agendado." }
    Write-Host "$agenda Corrija o problema acima e execute o instalador de novo." -ForegroundColor Red
    exit 1
}

# Test-NetConnection nao existe no PowerShell 2.0.
function Test-Porta([string]$Endereco, [int]$Porta) {
    $cliente = New-Object System.Net.Sockets.TcpClient
    try {
        $tentativa = $cliente.BeginConnect($Endereco, $Porta, $null, $null)
        if (-not $tentativa.AsyncWaitHandle.WaitOne(5000, $false)) { return $false }
        $cliente.EndConnect($tentativa)
        return $true
    } catch {
        return $false
    } finally {
        $cliente.Close()
    }
}

function Get-CaminhoInternet {
    return @{ Nome = "internet (HTTPS)"; Endpoint = $EndpointInternet; Teste = $EndpointInternet; VpnRecusada = $false }
}

# VPN quando o DNS interno resolve o private endpoint e a porta responde; senao internet.
function Get-Caminho {
    & ipconfig.exe /flushdns | Out-Null
    $enderecos = @()
    try {
        $enderecos = @([System.Net.Dns]::GetHostAddresses($EndpointFqdn) | ForEach-Object { $_.IPAddressToString })
    } catch { }
    if (($enderecos -contains $EndpointIp) -and (Test-Porta $EndpointIp 443)) {
        return @{ Nome = "VPN (private endpoint $EndpointIp)"; Endpoint = $EndpointFqdn; Teste = $EndpointIp; VpnRecusada = $false }
    }
    return Get-CaminhoInternet
}

# Pela VPN, DNS e porta podem responder e a nuvem ainda recusar (policy, endpoint): uma
# listagem curta do bucket confirma; se falhar, vale a internet. Deixa o rclone no caminho final.
function Confirm-Caminho($Caminho, $Chave, [string]$Rclone, [string]$Log) {
    Set-RemotoOci $Caminho.Endpoint $Chave
    if ($Caminho.Endpoint -ne $EndpointFqdn) { return $Caminho }
    $opcoes = @("--config", "/notfound", "--contimeout", "15s", "--timeout", "30s", "--retries", "1", "--low-level-retries", "1", "-q")
    if ($Log) { $opcoes += @("--log-file", $Log) }
    & $Rclone lsf $RaizBucket --dirs-only $opcoes | Out-Null
    if ($LASTEXITCODE -eq 0) { return $Caminho }
    $internet = Get-CaminhoInternet
    $internet.Nome = "internet (HTTPS; a nuvem recusou pela VPN)"
    $internet.VpnRecusada = $true
    Set-RemotoOci $internet.Endpoint $Chave
    return $internet
}

# Get-FileHash nao existe no PowerShell 2.0.
function Get-Sha256([string]$Arquivo) {
    try {
        $fluxo = [IO.File]::OpenRead($Arquivo)
        try {
            return [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($fluxo)).Replace("-", "")
        } finally {
            $fluxo.Close()
        }
    } catch {
        return "indisponivel"
    }
}

function Get-IpPublico {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072   # TLS 1.2
        return (New-Object Net.WebClient).DownloadString("https://ipv4.icanhazip.com").Trim()
    } catch {
        return "desconhecido"
    }
}

# UTF-8 ou, se nao for UTF-8 valido, ANSI.
function Read-TextoScript([string]$Arquivo) {
    $bytes = [IO.File]::ReadAllBytes($Arquivo)
    try {
        $texto = (New-Object Text.UTF8Encoding $false, $true).GetString($bytes)
    } catch {
        $texto = [Text.Encoding]::Default.GetString($bytes)
    }
    return $texto.TrimStart([char]0xFEFF)
}

# chave.dat: cifrado pelo Windows (DPAPI) para esta maquina; em outro computador nao abre.
function Save-Chave([string]$Arquivo, $Chave) {
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes(("{0}`n{1}" -f $Chave.AccessKey, $Chave.SecretKey))
    [IO.File]::WriteAllBytes($Arquivo, [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine))
}

function Read-Chave([string]$Arquivo) {
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Arquivo), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $partes = [Text.Encoding]::UTF8.GetString($bytes).Split("`n")
    return @{ AccessKey = $partes[0]; SecretKey = $partes[1] }
}

# Numa reinstalacao, Enter mantem a chave ja guardada.
function Request-Chave([string]$Arquivo) {
    $atual = $null
    if (Test-Path -LiteralPath $Arquivo) { try { $atual = Read-Chave $Arquivo } catch { } }
    Write-Host "  Para colar: Ctrl+V, botao direito do mouse ou icone da janela > Editar > Colar."
    if ($atual) { $pergunta = "  Chave ja guardada neste computador. Enter para manter, ou cole a nova Access Key" } else { $pergunta = "  Access Key" }
    $accessKey = Read-Resposta $pergunta
    if (-not $accessKey -and $atual) { return @{ Chave = $atual; Nova = $false } }
    if (-not $accessKey) { Stop-Instalacao "Access Key nao informada." }
    # Visivel ao colar (a leitura mascarada, -AsSecureString, nao aceita colar em todos os
    # consoles); depois a linha e reescrita com asteriscos, para nao ir parar em print ou copia.
    $secretKey = Read-Resposta "  Secret Key"
    if (-not $secretKey) { Stop-Instalacao "Secret Key nao informada." }
    try {
        [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
        Write-Host ("  Secret Key: " + ("*" * $secretKey.Length)).PadRight([Console]::WindowWidth - 1)
    } catch { }
    return @{ Chave = @{ AccessKey = $accessKey; SecretKey = $secretKey }; Nova = $true }
}

# Ordem: rclone.exe ao lado deste arquivo, o ja instalado na versao fixada ou o do site oficial.
function Get-Rclone {
    $aoLado = Join-Path $Base "rclone.exe"
    if (Test-Path -LiteralPath $aoLado) {
        return @{ Arquivo = $aoLado; Origem = "rclone.exe ao lado do instalador"; Temporario = "" }
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq "x86" -and -not $env:PROCESSOR_ARCHITEW6432) {
        Stop-Instalacao "Windows de 32 bits: coloque o rclone.exe de 32 bits ao lado deste arquivo e execute de novo."
    }
    # rclone 1.64 ou mais novo exige Windows 10/Server 2016.
    $fixado = $RcloneAtual
    if ([Environment]::OSVersion.Version -lt (New-Object Version 10, 0)) { $fixado = $RcloneLegado }
    $instalado = Join-Path $Destino "rclone.exe"
    if ((Get-Sha256 $instalado) -eq $fixado.Sha256) {
        return @{ Arquivo = $instalado; Origem = "ja instalado ($($fixado.Versao))"; Temporario = "" }
    }

    $pasta = Join-Path ([IO.Path]::GetTempPath()) ("backup-oci-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $pasta | Out-Null
    $nomeZip = "rclone-{0}-windows-amd64.zip" -f $fixado.Versao
    $url = "{0}/{1}/{2}" -f $RcloneSite, $fixado.Versao, $nomeZip
    $zip = Join-Path $pasta $nomeZip
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072   # TLS 1.2
        (New-Object Net.WebClient).DownloadFile($url, $zip)
    } catch {
        Write-Host ("  Falha ao baixar {0}: {1}" -f $url, $_.Exception.Message) -ForegroundColor Yellow
        Remove-Item -LiteralPath $pasta -Recurse -Force -ErrorAction SilentlyContinue
        Stop-Instalacao ("Sem acesso ao site do rclone. Coloque o rclone.exe ({0}) ao lado deste arquivo e execute de novo." -f $fixado.Versao)
    }
    $exe = Join-Path $pasta "rclone.exe"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $arquivoZip = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $entrada = @($arquivoZip.Entries | Where-Object { $_.Name -eq "rclone.exe" })[0]
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entrada, $exe, $true)
        } finally {
            $arquivoZip.Dispose()
        }
    } catch {
        # PowerShell 2.0: o Shell do Windows pode terminar a copia depois de retornar.
        $shell = New-Object -ComObject Shell.Application
        $shell.NameSpace($pasta).CopyHere($shell.NameSpace($zip).Items(), 0x14)
        $exe = Join-Path $pasta ("rclone-{0}-windows-amd64\rclone.exe" -f $fixado.Versao)
        $tamanho = -1
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            $atual = (Get-Item -LiteralPath $exe).Length
            if ($atual -gt 0 -and $atual -eq $tamanho) { break }
            $tamanho = $atual
        }
    }
    $obtido = Get-Sha256 $exe
    if ($obtido -ne $fixado.Sha256) {
        Remove-Item -LiteralPath $pasta -Recurse -Force -ErrorAction SilentlyContinue
        Stop-Instalacao ("O rclone baixado nao confere: SHA256 {0}, esperado {1}." -f $obtido, $fixado.Sha256)
    }
    return @{ Arquivo = $exe; Origem = "baixado do site oficial ($($fixado.Versao)), SHA256 conferido"; Temporario = $pasta }
}

function Test-Administrador {
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $administrador = (New-Object Security.Principal.WindowsPrincipal $identidade).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $administrador) { Stop-Instalacao "Execute este arquivo como administrador: botao direito, Executar como administrador." }
}

# ------------------ Tela interativa: setas, Espaco e numeros ------------------

# Teclado de verdade; sem ele (entrada redirecionada, sessao remota), as escolhas sao digitadas.
function Test-Interativo {
    try { $null = $Host.UI.RawUI.KeyAvailable; return $true } catch { return $false }
}

# Uma tecla por nome: Cima, Baixo, Inicio, Fim, PgCima, PgBaixo, Espaco, Enter, Esc, digito ou letra.
function Read-Tecla {
    $tecla = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    $codigo = [int]$tecla.VirtualKeyCode
    $nomes = @{ 38 = "Cima"; 40 = "Baixo"; 36 = "Inicio"; 35 = "Fim"; 33 = "PgCima"; 34 = "PgBaixo"; 32 = "Espaco"; 13 = "Enter"; 27 = "Esc" }
    if ($nomes.ContainsKey($codigo)) { return $nomes[$codigo] }
    if ($codigo -ge 96 -and $codigo -le 105) { return [string]($codigo - 96) }
    return ([string]$tecla.Character).ToUpper()
}

function Test-TeclaPendente {
    try { return [bool]$Host.UI.RawUI.KeyAvailable } catch { return $false }
}

# Numero digitado: com 10 itens ou mais, um segundo digito logo em seguida (ate 0,7 s) forma o
# numero; outra tecla volta em Proxima, para ser tratada depois.
function Read-Numero([string]$Digito, [int]$Maximo) {
    $resultado = @{ Numero = [int]$Digito; Proxima = $null }
    if ($Maximo -lt 10) { return $resultado }
    for ($i = 0; $i -lt 14 -and -not (Test-TeclaPendente); $i++) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-TeclaPendente)) { return $resultado }
    $segunda = Read-Tecla
    if ($segunda -match '^[0-9]$' -and ([int]$Digito * 10 + [int]$segunda) -le $Maximo) {
        $resultado.Numero = [int]$Digito * 10 + [int]$segunda
    } else {
        $resultado.Proxima = $segunda
    }
    return $resultado
}

# Desenha as linhas a partir de $Topo, por cima do desenho anterior (-1: onde o cursor estiver)
# e devolve o $Topo do proximo. Sem console (testes, sessao remota), escreve em sequencia.
function Write-Tela([int]$Topo, $Linhas) {
    $largura = 80
    $frente = [ConsoleColor]::Gray
    $fundo = [ConsoleColor]::Black
    $console = $true
    try {
        $largura = [Console]::WindowWidth
        $frente = $Host.UI.RawUI.ForegroundColor
        $fundo = $Host.UI.RawUI.BackgroundColor
        [Console]::CursorVisible = $false
        if ($Topo -ge 0) { [Console]::SetCursorPosition(0, $Topo) }
    } catch { $console = $false }
    if ([int]$frente -lt 0 -or [int]$frente -gt 15) { $frente = [ConsoleColor]::Gray }
    if ([int]$fundo -lt 0 -or [int]$fundo -gt 15) { $fundo = [ConsoleColor]::Black }
    foreach ($linha in @($Linhas)) {
        $texto = [string]$linha.Texto
        if ($texto.Length -gt $largura - 1) { $texto = $texto.Substring(0, $largura - 1) }
        $corFrente = $frente
        $corFundo = $fundo
        if ($linha.Destaque) { $corFrente = $fundo; $corFundo = $frente } elseif ($linha.Cor) { $corFrente = $linha.Cor }
        Write-Host $texto.PadRight($largura - 1) -ForegroundColor $corFrente -BackgroundColor $corFundo
    }
    if (-not $console) { return -1 }
    try { return [Console]::CursorTop - @($Linhas).Count } catch { return -1 }
}

function Close-Tela {
    try { [Console]::CursorVisible = $true } catch { }
}

# Uma opcao: setas e Enter, ou o numero direto. Sem teclado de verdade, pergunta o numero.
# $Opcoes: hashtables com Tecla (o numero, em texto) e Texto.
function Select-Opcao([string]$Titulo, $Opcoes) {
    $Opcoes = @($Opcoes)
    if (-not (Test-Interativo)) {
        Write-Host ""
        Write-Host $Titulo -ForegroundColor Cyan
        foreach ($opcao in $Opcoes) { Write-Host ("  {0}. {1}" -f $opcao.Tecla, $opcao.Texto) }
        return (Read-Resposta "Opcao")
    }
    $maximo = 0
    foreach ($opcao in $Opcoes) { if ([int]$opcao.Tecla -gt $maximo) { $maximo = [int]$opcao.Tecla } }
    $atual = 0
    $topo = -1
    $pendente = $null
    $escolha = $null
    Write-Host ""
    while ($true) {
        $linhas = @(@{ Texto = $Titulo; Cor = "Cyan" })
        for ($i = 0; $i -lt $Opcoes.Count; $i++) {
            $seta = "  "
            if ($i -eq $atual) { $seta = "> " }
            $linhas += @{ Texto = ("{0}{1}. {2}" -f $seta, $Opcoes[$i].Tecla, $Opcoes[$i].Texto); Destaque = ($i -eq $atual) }
        }
        $linhas += @{ Texto = "  Setas e Enter, ou o numero da opcao."; Cor = "DarkGray" }
        $topo = Write-Tela $topo $linhas
        if ($null -ne $escolha) { Close-Tela; return $escolha }
        if ($pendente) { $tecla = $pendente; $pendente = $null } else { $tecla = Read-Tecla }
        if ($tecla -eq "Cima") { $atual = ($atual + $Opcoes.Count - 1) % $Opcoes.Count }
        elseif ($tecla -eq "Baixo") { $atual = ($atual + 1) % $Opcoes.Count }
        elseif ($tecla -eq "Inicio") { $atual = 0 }
        elseif ($tecla -eq "Fim") { $atual = $Opcoes.Count - 1 }
        elseif ($tecla -eq "Enter") { $escolha = [string]$Opcoes[$atual].Tecla }
        elseif ($tecla -match '^[0-9]$') {
            $lido = Read-Numero $tecla $maximo
            $pendente = $lido.Proxima
            for ($i = 0; $i -lt $Opcoes.Count; $i++) {
                if ([string]$Opcoes[$i].Tecla -eq [string]$lido.Numero) { $atual = $i; $escolha = [string]$lido.Numero }
            }
        }
    }
}

# ------------- Escolha das pastas: compartilhamentos, tamanho e marcacao -------------

function Format-Caminho([string]$Caminho) {
    $resultado = ([string]$Caminho).Trim().Trim('"').TrimEnd('\')
    if ($resultado -match '^[A-Za-z]:$') { $resultado += '\' }
    return $resultado
}

# $Filho e $Pai ou fica dentro dele.
function Test-Dentro([string]$Filho, [string]$Pai) {
    if (-not $Filho -or -not $Pai) { return $false }
    return ($Filho.TrimEnd('\') + '\').StartsWith($Pai.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Format-Tamanho([long]$Bytes) {
    if ($Bytes -lt 0) { return "?" }
    if ($Bytes -ge 1TB) { return "{0:N1} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N0} MB" -f ($Bytes / 1MB) }
    return "{0:N0} KB" -f [Math]::Ceiling($Bytes / 1KB)
}

# Pastas do bloco de edicao, sem os exemplos do modelo.
function Get-PastasConfiguradas {
    return @(@($Pastas) | Where-Object { $_ -and $_ -notmatch '^[A-Za-z]:\\Exemplo\\' } | ForEach-Object { Format-Caminho $_ })
}

# Compartilhamentos de disco (WMI, do Windows 2003 em diante), sem os administrativos (C$, ADMIN$).
function Get-CompartilhamentosBrutos {
    return @(Get-WmiObject Win32_Share -Filter "Type = 0" | ForEach-Object { New-Object PSObject -Property @{ Nome = [string]$_.Name; Caminho = [string]$_.Path } })
}

# Os que podem entrar no backup: fora os do sistema (impressoras, controlador de dominio, pasta
# do Windows), so caminho local que existe.
function Get-Compartilhamentos {
    $sistema = @("print$", "NETLOGON", "SYSVOL")
    $windows = Format-Caminho $env:SystemRoot
    $lista = @()
    foreach ($compartilhamento in @(Get-CompartilhamentosBrutos)) {
        if ($sistema -contains $compartilhamento.Nome) { continue }
        $caminho = Format-Caminho $compartilhamento.Caminho
        if ($caminho -notmatch '^[A-Za-z]:\\' -or (Test-Dentro $caminho $windows)) { continue }
        if (-not (Test-Path -LiteralPath $caminho -PathType Container)) { continue }
        $lista += New-Object PSObject -Property @{ Nome = $compartilhamento.Nome; Caminho = $caminho }
    }
    return $lista
}

# Tamanho de cada pasta pelo robocopy /L (so lista, nao copia), todas ao mesmo tempo; a que nao
# terminar em $Segundos fica sem tamanho (-1).
function Measure-Pastas([string[]]$Caminhos, [int]$Segundos) {
    $tamanhos = @{}
    $vazio = Join-Path ([IO.Path]::GetTempPath()) ("backup-oci-tamanho-" + [Guid]::NewGuid().ToString("N"))
    $medicoes = @()
    foreach ($caminho in @($Caminhos)) {
        $origem = $caminho
        if ($origem.EndsWith('\')) { $origem += '.' }
        $registro = [IO.Path]::GetTempFileName()
        $info = New-Object Diagnostics.ProcessStartInfo "robocopy.exe", ("`"{0}`" `"{1}`" /L /E /BYTES /NFL /NDL /NJH /NC /NP /XJ /R:0 /W:0 /LOG:`"{2}`"" -f $origem, $vazio, $registro)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $processo = $null
        try { $processo = [Diagnostics.Process]::Start($info) } catch { }
        $medicoes += @{ Caminho = $caminho; Registro = $registro; Processo = $processo }
    }
    $limite = (Get-Date).AddSeconds($Segundos)
    foreach ($medicao in $medicoes) {
        $tamanho = [long]-1
        $processo = $medicao.Processo
        if ($processo) {
            $resta = [int][Math]::Max(0, ($limite - (Get-Date)).TotalMilliseconds)
            if ($processo.WaitForExit($resta)) {
                foreach ($linha in @(Get-Content -LiteralPath $medicao.Registro)) {
                    if ($linha -match '^\s*Bytes\s*:\s*(\d+)') { $tamanho = [long]$Matches[1]; break }
                }
            } else {
                try { $processo.Kill(); [void]$processo.WaitForExit(5000) } catch { }
            }
        }
        $tamanhos[$medicao.Caminho] = $tamanho
        Remove-Item -LiteralPath $medicao.Registro -Force -ErrorAction SilentlyContinue
    }
    return $tamanhos
}

# Itens da escolha: as pastas compartilhadas e as ja configuradas que nao sao compartilhamento.
# Marcadas: as configuradas; na primeira vez, todas menos a pasta de perfis (C:\Users), cada
# perfil (C:\Users\fulano) e raiz de disco. Pasta de dados dentro de um perfil vem marcada.
function Get-ItensPastas([string[]]$Configuradas) {
    $Configuradas = @($Configuradas)
    $itens = @()
    # WMI com problema (comum em servidor antigo) nao impede a instalacao: segue com "Outra pasta".
    $compartilhamentos = @()
    try { $compartilhamentos = @(Get-Compartilhamentos) } catch {
        Write-Host ("  Aviso: nao foi possivel listar as pastas compartilhadas ({0}). Use 'Outra pasta' para incluir as pastas." -f $_.Exception.Message) -ForegroundColor Yellow
    }
    foreach ($compartilhamento in $compartilhamentos) {
        $repetido = @($itens | Where-Object { $_.Caminho -eq $compartilhamento.Caminho })
        if ($repetido.Count -gt 0) { $repetido[0].Nome = $repetido[0].Nome + ", " + $compartilhamento.Nome; continue }
        $itens += New-Object PSObject -Property @{ Nome = $compartilhamento.Nome; Caminho = $compartilhamento.Caminho; Tamanho = [long]-1; Marcado = $false }
    }
    foreach ($pasta in $Configuradas) {
        if (@($itens | Where-Object { $_.Caminho -eq $pasta }).Count -eq 0) {
            $itens += New-Object PSObject -Property @{ Nome = ""; Caminho = $pasta; Tamanho = [long]-1; Marcado = $false }
        }
    }
    $perfis = "C:\Users"
    if ($env:PUBLIC) { $perfis = Split-Path -Parent $env:PUBLIC }
    foreach ($item in $itens) {
        if ($Configuradas.Count -gt 0) { $item.Marcado = ($Configuradas -contains $item.Caminho) }
        else { $item.Marcado = -not (($item.Caminho -eq $perfis) -or ((Split-Path -Parent $item.Caminho) -eq $perfis) -or ($item.Caminho -match '^[A-Za-z]:\\$')) }
    }
    if ($itens.Count -gt 0) {
        $tamanhos = Measure-Pastas @($itens | ForEach-Object { $_.Caminho }) 60
        foreach ($item in $itens) { $item.Tamanho = $tamanhos[$item.Caminho] }
    }
    return $itens
}

# Linhas da lista: [x] marcada, > linha atual; com mais itens que a tela, mostra uma janela
# em volta da linha atual. A ultima linha e "Outra pasta" (sem -SemOutra).
function Get-LinhasPastas($Itens, [int]$Atual, [int]$Altura, [switch]$SemOutra) {
    $Itens = @($Itens)
    $total = $Itens.Count
    if (-not $SemOutra) { $total++ }
    $inicio = 0
    $fim = $total - 1
    $rolagem = $total -gt $Altura
    if ($rolagem) {
        $inicio = [Math]::Max(0, [Math]::Min($Atual - [int][Math]::Floor($Altura / 2), $total - $Altura))
        $fim = $inicio + $Altura - 1
    }
    $largura = 10
    foreach ($item in $Itens) { if ($item.Caminho.Length -gt $largura) { $largura = $item.Caminho.Length } }
    $largura = [Math]::Min($largura, 50)
    $linhas = @()
    if ($rolagem) {
        $texto = ""
        if ($inicio -gt 0) { $texto = "       ... mais {0} acima" -f $inicio }
        $linhas += @{ Texto = $texto; Cor = "DarkGray" }
    }
    for ($i = $inicio; $i -le $fim; $i++) {
        $seta = "  "
        if ($i -eq $Atual) { $seta = "> " }
        if ($i -eq $Itens.Count) {
            $linhas += @{ Texto = ("{0}       Outra pasta (digitar o caminho)..." -f $seta); Destaque = ($i -eq $Atual) }
            continue
        }
        $item = $Itens[$i]
        $caixa = "[ ]"
        if ($item.Marcado) { $caixa = "[x]" }
        $compartilhada = ""
        if ($item.Nome) { $compartilhada = "\\{0}\{1}" -f $env:COMPUTERNAME, $item.Nome }
        $linhas += @{ Texto = ("{0}{1} {2,2}. {3}  {4,9}  {5}" -f $seta, $caixa, ($i + 1), $item.Caminho.PadRight($largura), (Format-Tamanho $item.Tamanho), $compartilhada); Destaque = ($i -eq $Atual) }
    }
    if ($rolagem) {
        $texto = ""
        if ($fim -lt $total - 1) { $texto = "       ... mais {0} abaixo" -f ($total - 1 - $fim) }
        $linhas += @{ Texto = $texto; Cor = "DarkGray" }
    }
    return $linhas
}

function Get-ResumoPastas($Itens) {
    $quantidade = 0
    $bytes = [long]0
    $semTamanho = 0
    foreach ($item in @($Itens)) {
        if (-not $item.Marcado) { continue }
        $quantidade++
        if ($item.Tamanho -ge 0) { $bytes += $item.Tamanho } else { $semTamanho++ }
    }
    $texto = "  Marcadas: {0} pasta(s), {1}" -f $quantidade, (Format-Tamanho $bytes)
    if ($semTamanho -gt 0) { $texto += " (+ {0} sem tamanho calculado)" -f $semTamanho }
    return $texto
}

# "Outra pasta": caminho digitado, local e existente; entra marcado na lista.
function Add-OutraPasta($Itens, [int]$Topo, [int]$Linhas) {
    $Itens = @($Itens)
    $resultado = @{ Itens = $Itens; Mensagem = ""; Indice = -1 }
    try { if ($Topo -ge 0) { [Console]::SetCursorPosition(0, $Topo + $Linhas) }; [Console]::CursorVisible = $true } catch { }
    $digitado = Read-Resposta "  Caminho completo da pasta, ex.: D:\Dados (Enter cancela)"
    try { if ($Topo -ge 0) { [Console]::SetCursorPosition(0, $Topo + $Linhas); Write-Host (" " * ([Console]::WindowWidth - 1)) } } catch { }
    if (-not $digitado) { return $resultado }
    $caminho = Format-Caminho $digitado
    if ($caminho -notmatch '^[A-Za-z]:\\') { $resultado.Mensagem = "  Use o caminho local, ex.: D:\Dados (pasta de rede nao funciona)."; return $resultado }
    if (-not (Test-Path -LiteralPath $caminho -PathType Container)) { $resultado.Mensagem = "  Pasta nao encontrada: $caminho"; return $resultado }
    for ($i = 0; $i -lt $Itens.Count; $i++) {
        if ($Itens[$i].Caminho -eq $caminho) { $Itens[$i].Marcado = $true; $resultado.Indice = $i; return $resultado }
    }
    $tamanhos = Measure-Pastas @($caminho) 30
    $resultado.Itens = $Itens + @(New-Object PSObject -Property @{ Nome = ""; Caminho = $caminho; Tamanho = $tamanhos[$caminho]; Marcado = $true })
    $resultado.Indice = $Itens.Count
    return $resultado
}

# Escolha das pastas: setas movem, Espaco ou numero marca, A todas, N nenhuma, Enter confirma,
# Esc cancela. Devolve @{ Cancelado; Pastas }.
function Select-Pastas($Itens) {
    $Itens = @($Itens)
    if (-not (Test-Interativo)) { return (Select-PastasDigitando $Itens) }
    $atual = 0
    $topo = -1
    $pendente = $null
    $mensagem = ""
    $altura = 15
    try { $altura = [Math]::Max(5, [Console]::WindowHeight - 9) } catch { }
    Write-Host ""
    while ($true) {
        $linhas = @(@{ Texto = "Pastas do backup: setas movem, Espaco ou numero marca, A todas, N nenhuma, Enter confirma, Esc cancela"; Cor = "Cyan" })
        $linhas += @(Get-LinhasPastas $Itens $atual $altura)
        $linhas += @{ Texto = (Get-ResumoPastas $Itens) }
        $linhas += @{ Texto = $mensagem; Cor = "Yellow" }
        $topo = Write-Tela $topo $linhas
        $mensagem = ""
        if ($pendente) { $tecla = $pendente; $pendente = $null } else { $tecla = Read-Tecla }
        $total = $Itens.Count + 1
        if ($tecla -eq "Cima") { $atual = ($atual + $total - 1) % $total }
        elseif ($tecla -eq "Baixo") { $atual = ($atual + 1) % $total }
        elseif ($tecla -eq "PgCima") { $atual = [Math]::Max(0, $atual - $altura) }
        elseif ($tecla -eq "PgBaixo") { $atual = [Math]::Min($total - 1, $atual + $altura) }
        elseif ($tecla -eq "Inicio") { $atual = 0 }
        elseif ($tecla -eq "Fim") { $atual = $total - 1 }
        elseif ($tecla -eq "A") { foreach ($item in $Itens) { $item.Marcado = $true } }
        elseif ($tecla -eq "N") { foreach ($item in $Itens) { $item.Marcado = $false } }
        elseif ($tecla -match '^[0-9]$') {
            $lido = Read-Numero $tecla $Itens.Count
            $pendente = $lido.Proxima
            if ($lido.Numero -ge 1 -and $lido.Numero -le $Itens.Count) {
                $atual = $lido.Numero - 1
                $Itens[$atual].Marcado = -not $Itens[$atual].Marcado
            }
        }
        elseif (($tecla -eq "Espaco" -or $tecla -eq "Enter") -and $atual -eq $Itens.Count) {
            $outra = Add-OutraPasta $Itens $topo $linhas.Count
            $Itens = @($outra.Itens)
            $mensagem = $outra.Mensagem
            if ($outra.Indice -ge 0) { $atual = $outra.Indice }
        }
        elseif ($tecla -eq "Espaco") { $Itens[$atual].Marcado = -not $Itens[$atual].Marcado }
        elseif ($tecla -eq "Enter") {
            $marcadas = @($Itens | Where-Object { $_.Marcado } | ForEach-Object { $_.Caminho })
            if ($marcadas.Count -gt 0) { Close-Tela; return @{ Cancelado = $false; Pastas = $marcadas } }
            $mensagem = "  Marque pelo menos uma pasta (Espaco ou o numero)."
        }
        elseif ($tecla -eq "Esc") { Close-Tela; return @{ Cancelado = $true } }
    }
}

# Sem teclado de verdade: a mesma escolha, digitando os numeros.
function Select-PastasDigitando($Itens) {
    $Itens = @($Itens)
    $vazias = 0
    while ($true) {
        Write-Host ""
        Write-Host "Pastas do backup:" -ForegroundColor Cyan
        foreach ($linha in @(Get-LinhasPastas $Itens -1 1000 -SemOutra)) { Write-Host $linha.Texto }
        Write-Host (Get-ResumoPastas $Itens)
        $resposta = Read-Resposta "Numeros para marcar ou desmarcar (ex.: 1,3), O para outra pasta, 0 cancela, Enter confirma"
        if ($resposta -eq "0") { return @{ Cancelado = $true } }
        if (-not $resposta) {
            $marcadas = @($Itens | Where-Object { $_.Marcado } | ForEach-Object { $_.Caminho })
            if ($marcadas.Count -gt 0) { return @{ Cancelado = $false; Pastas = $marcadas } }
            Write-Host "  Marque pelo menos uma pasta." -ForegroundColor Yellow
            $vazias++
            if ($vazias -ge 3) { return @{ Cancelado = $true } }
            continue
        }
        if ($resposta -match '^[oO]$') {
            $outra = Add-OutraPasta $Itens -1 0
            $Itens = @($outra.Itens)
            if ($outra.Mensagem) { Write-Host $outra.Mensagem -ForegroundColor Yellow }
            continue
        }
        foreach ($parte in $resposta.Split([string[]]@(",", ";", " "), [StringSplitOptions]::RemoveEmptyEntries)) {
            $numero = 0
            if ([int]::TryParse($parte, [ref]$numero) -and $numero -ge 1 -and $numero -le $Itens.Count) {
                $Itens[$numero - 1].Marcado = -not $Itens[$numero - 1].Marcado
            } else {
                Write-Host "  Ignorado: $parte" -ForegroundColor Yellow
            }
        }
    }
}

# Pasta dentro de outra escolhida sai da lista: os arquivos ja vao com a de fora.
function Optimize-Pastas([string[]]$Lista) {
    $resultado = @()
    foreach ($pasta in @($Lista)) {
        $externas = @(@($Lista) | Where-Object { $_ -ne $pasta -and (Test-Dentro $pasta $_) })
        if ($externas.Count -gt 0) { Write-Host ("  {0} ja vai junto com {1}" -f $pasta, $externas[0]) -ForegroundColor Yellow; continue }
        if ($resultado -notcontains $pasta) { $resultado += $pasta }
    }
    return $resultado
}

function Read-Horario([string]$Atual) {
    for ($i = 0; $i -lt 3; $i++) {
        $resposta = Read-Resposta ("  Horario do backup diario, HH:mm (Enter = {0})" -f $Atual)
        if (-not $resposta) { return $Atual }
        if ($resposta -match '^[0-9]:[0-5][0-9]$') { $resposta = "0" + $resposta }
        if ($resposta -match '^([01][0-9]|2[0-3]):[0-5][0-9]$') { return $resposta }
        Write-Host "  Use HH:mm, por exemplo 22:00." -ForegroundColor Yellow
    }
    return $Atual
}

# Grava pastas e horario no bloco de edicao deste arquivo, na mesma codificacao e sem mexer no
# cabecalho: o cmd continua lendo o arquivo pela posicao depois que o PowerShell termina.
# Localiza os trechos pelos tokens do PowerShell (vale qualquer formatacao do bloco).
function Set-ConfiguracaoNoArquivo([string]$Arquivo, [string[]]$NovasPastas, [string]$NovoHorario) {
    $bytes = [IO.File]::ReadAllBytes($Arquivo)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    try {
        $texto = (New-Object Text.UTF8Encoding $false, $true).GetString($bytes)
        $codificacao = New-Object Text.UTF8Encoding $bom
    } catch {
        $texto = [Text.Encoding]::Default.GetString($bytes)
        $codificacao = [Text.Encoding]::Default
    }
    $texto = $texto.TrimStart([char]0xFEFF)
    $quebra = "`n"
    if ($texto.Contains("`r`n")) { $quebra = "`r`n" }
    $erros = $null
    $tokens = @([System.Management.Automation.PSParser]::Tokenize($texto, [ref]$erros))
    $trechoPastas = $null
    $trechoHorario = $null
    for ($i = 0; $i -lt $tokens.Count - 2; $i++) {
        if ($tokens[$i].Type -ne "Variable" -or $tokens[$i + 1].Content -ne "=") { continue }
        if ($tokens[$i].Content -eq "Pastas" -and -not $trechoPastas) {
            $fim = $tokens[$i + 2].Start + $tokens[$i + 2].Length
            if ($tokens[$i + 2].Type -eq "GroupStart") {
                $nivel = 0
                for ($j = $i + 2; $j -lt $tokens.Count; $j++) {
                    if ($tokens[$j].Type -eq "GroupStart") { $nivel++ }
                    elseif ($tokens[$j].Type -eq "GroupEnd") { $nivel--; if ($nivel -eq 0) { $fim = $tokens[$j].Start + $tokens[$j].Length; break } }
                }
            }
            $trechoPastas = @{ Inicio = $tokens[$i].Start; Fim = $fim }
        } elseif ($tokens[$i].Content -eq "Horario" -and -not $trechoHorario -and $tokens[$i + 2].Type -eq "String") {
            $trechoHorario = @{ Inicio = $tokens[$i].Start; Fim = $tokens[$i + 2].Start + $tokens[$i + 2].Length }
        }
    }
    if (-not $trechoPastas -or -not $trechoHorario) { throw "bloco de edicao nao reconhecido em $Arquivo" }
    $linhasPastas = @($NovasPastas | ForEach-Object { "    '" + $_.Replace("'", "''") + "'" })
    $novoPastas = '$Pastas = @(' + $quebra + ($linhasPastas -join ("," + $quebra)) + $quebra + ')'
    $novoHorarioTexto = '$Horario = "' + $NovoHorario + '"'
    # Do fim para o comeco, para as posicoes do outro trecho continuarem valendo.
    $trechos = @(@{ T = $trechoPastas; Novo = $novoPastas }, @{ T = $trechoHorario; Novo = $novoHorarioTexto }) | Sort-Object { $_.T.Inicio } -Descending
    foreach ($trecho in $trechos) {
        $texto = $texto.Substring(0, $trecho.T.Inicio) + $trecho.Novo + $texto.Substring($trecho.T.Fim)
    }
    [IO.File]::WriteAllText($Arquivo, $texto, $codificacao)
}

# Primeira vez, ou com teclado: mostra os compartilhamentos para escolher e grava a escolha (e o
# horario) neste arquivo. Devolve @{ Pastas; Horario; Conhecidos } (Conhecidos: $null sem escolha).
function Select-Configuracao {
    $configuradas = @(Get-PastasConfiguradas)
    $resultado = @{ Pastas = $configuradas; Horario = $Horario; Conhecidos = $null }
    if (-not (Test-Interativo) -and $configuradas.Count -gt 0) { return $resultado }
    Write-Host "  Procurando as pastas compartilhadas e calculando o tamanho (ate 1 min)..."
    $itens = @(Get-ItensPastas $configuradas)
    $escolha = Select-Pastas $itens
    if ($escolha.Cancelado) {
        if ($configuradas.Count -eq 0) { Stop-Instalacao "Nenhuma pasta escolhida." }
        Write-Host "  Escolha cancelada: ficam as pastas atuais." -ForegroundColor Yellow
        return $resultado
    }
    $resultado.Pastas = @(Optimize-Pastas @($escolha.Pastas))
    try { $resultado.Conhecidos = @(Get-Compartilhamentos | ForEach-Object { $_.Caminho }) } catch { $resultado.Conhecidos = $null }
    if (Test-Interativo) { $resultado.Horario = Read-Horario $Horario }
    if (($resultado.Pastas -join "|") -ne ($configuradas -join "|") -or $resultado.Horario -ne $Horario) {
        Set-ConfiguracaoNoArquivo $Script $resultado.Pastas $resultado.Horario
        Write-Host "  OK  escolha gravada neste arquivo (vale para reinstalar e para um servidor novo)" -ForegroundColor Green
    }
    return $resultado
}

function Install-Backup {
    Write-Etapa 1 "Pastas do backup e configuracao"
    if ($Servidor -notmatch '^[a-z0-9-]{1,40}$') { Stop-Instalacao "Servidor '$Servidor' invalido: use minusculas, numeros e hifen." }
    $configuracao = Select-Configuracao
    $Pastas = @($configuracao.Pastas)
    $Horario = $configuracao.Horario
    if ($Horario -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') { Stop-Instalacao "Horario '$Horario' invalido (use HH:mm)." }
    $ausentes = 0
    foreach ($pasta in @($Pastas)) {
        if (Test-Path -LiteralPath $pasta) {
            Write-Host "  OK              $pasta" -ForegroundColor Green
        } else {
            Write-Host "  NAO ENCONTRADA  $pasta" -ForegroundColor Yellow
            $ausentes++
        }
    }
    if ($ausentes -gt 0) { Stop-Instalacao "Pasta(s) nao encontrada(s). Corrija os caminhos no bloco de edicao." }

    Write-Etapa 2 "Chave de acesso (Access Key e Secret Key, no cofre de senhas do TI)"
    $arquivoChave = Join-Path $Destino "chave.dat"
    $pedido = Request-Chave $arquivoChave
    if ($pedido.Nova) { Write-Host "  OK  chave nova (guardada depois do teste de envio)" -ForegroundColor Green } else { Write-Host "  OK  chave mantida" -ForegroundColor Green }

    Write-Etapa 3 "Escolhendo o caminho ate a nuvem"
    $caminho = Get-Caminho
    Write-Host ("  OK  {0}" -f $caminho.Nome) -ForegroundColor Green

    Write-Etapa 4 "Testando a conexao com a nuvem"
    if (-not (Test-Porta $caminho.Teste 443)) {
        Stop-Instalacao ("Sem conexao com {0} na porta 443. Verificar o acesso deste computador a internet." -f $caminho.Teste)
    }
    Write-Host "  OK  porta 443 acessivel" -ForegroundColor Green

    Write-Etapa 5 "Obtendo o rclone"
    $rcloneObtido = Get-Rclone
    Write-Host ("  OK  {0}" -f $rcloneObtido.Origem) -ForegroundColor Green

    Write-Etapa 6 "Preparando $Destino"
    New-Item -ItemType Directory -Path (Join-Path $Destino "logs") -Force | Out-Null
    # So SYSTEM e Administradores, por SID (os nomes mudam com o idioma). Permissao so na
    # pasta e itens herdando (/reset): com icacls /T a ACL dos arquivos ficava vazia.
    & icacls.exe $Destino /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Instalacao "Falha ao restringir as permissoes de $Destino." }
    & icacls.exe "$Destino\*" /reset /T /C /Q | Out-Null
    $rcloneInstalado = Join-Path $Destino "rclone.exe"
    if ($rcloneObtido.Arquivo -ne $rcloneInstalado) { Copy-Item -LiteralPath $rcloneObtido.Arquivo -Destination $rcloneInstalado -Force }
    if ($rcloneObtido.Temporario) { Remove-Item -LiteralPath $rcloneObtido.Temporario -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "  OK  rclone.exe e permissoes" -ForegroundColor Green

    Write-Etapa 7 "Testando o envio de um arquivo para a nuvem"
    $rclone = $rcloneInstalado
    $logTeste = Join-Path $Destino "logs\instalacao.log"
    $marca = Join-Path $Destino "logs\instalacao.txt"
    $textoMarca = "Instalado em {0} por {1} no {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"), $env:USERNAME, $env:COMPUTERNAME
    Set-Content -LiteralPath $marca -Value $textoMarca -Encoding ASCII
    try {
        $caminho = Confirm-Caminho $caminho $pedido.Chave $rclone $logTeste
        & $rclone copyto $marca "$Remoto/_instalacao.txt" --config /notfound --log-file $logTeste --log-level INFO --contimeout 15s --timeout 60s --retries 1 --low-level-retries 2
    } catch {
        # O Windows nem iniciou o rclone: provavel antivirus. Liberar, nao contornar.
        $motivo = $_.Exception.Message
        if ($_.Exception.InnerException) { $motivo = $_.Exception.InnerException.Message }
        Write-Host ("  O Windows nao deixou executar o rclone.exe: {0}" -f $motivo) -ForegroundColor Yellow
        Write-Host "  Provavel bloqueio do antivirus: libere este arquivo como aplicativo confiavel (no Kaspersky:" -ForegroundColor Yellow
        Write-Host "  Controle de Aplicativos e Exclusoes/Aplicativos confiaveis):" -ForegroundColor Yellow
        Write-Host ("    Caminho: {0}" -f $rclone)
        Write-Host ("    SHA256:  {0}" -f (Get-Sha256 $rclone))
        Stop-Instalacao "O antivirus bloqueou o rclone.exe. Depois de liberar, execute o instalador de novo."
    }
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $logTeste | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-Host ("  Caminho: {0}. IP publico deste computador: {1}" -f $caminho.Nome, (Get-IpPublico)) -ForegroundColor Yellow
        Stop-Instalacao "A nuvem recusou o envio (detalhes acima e em $logTeste)."
    }
    Write-Host "  OK  arquivo de teste enviado" -ForegroundColor Green
    if ($caminho.VpnRecusada) {
        Write-Host ("  Aviso: a VPN responde, mas a nuvem recusou o acesso por ela; o backup vai pela internet (detalhes em {0})." -f $logTeste) -ForegroundColor Yellow
    }
    # Script e chave so depois do teste: numa reinstalacao que falhar, fica a instalacao anterior.
    # A tarefa executa esta copia .ps1, em UTF-8 com BOM para o PowerShell 2.0.
    # A copia .cmd abre o menu; o cmd nao aceita BOM.
    $scriptInstalado = Join-Path $Destino "backup-oci.ps1"
    $menuInstalado = Join-Path $Destino "backup-oci.cmd"
    if ($Script -ne $scriptInstalado) {
        $texto = Read-TextoScript $Script
        [IO.File]::WriteAllText($scriptInstalado, $texto, (New-Object Text.UTF8Encoding $true))
        if ($Script -ne $menuInstalado) { [IO.File]::WriteAllText($menuInstalado, $texto, (New-Object Text.UTF8Encoding $false)) }
    }
    if ($pedido.Nova) { Save-Chave $arquivoChave $pedido.Chave }
    # Compartilhamentos vistos na escolha: o backup so avisa dos criados depois.
    if ($null -ne $configuracao.Conhecidos) {
        [IO.File]::WriteAllLines((Join-Path $Destino "compartilhamentos.txt"), [string[]]@($configuracao.Conhecidos), (New-Object Text.UTF8Encoding $false))
    }
    Write-Host "  OK  script e chave instalados (chave cifrada, so abre neste computador)" -ForegroundColor Green

    Write-Etapa 8 "Agendando o backup diario as $Horario"
    # Por XML: o padrao do schtasks nao roda na bateria nem recupera o horario perdido.
    # Primeiro disparo no futuro, para nao rodar na hora da instalacao.
    $primeira = [DateTime]::ParseExact($Horario, "HH:mm", [Globalization.CultureInfo]::InvariantCulture)
    if ($primeira -le (Get-Date)) { $primeira = $primeira.AddDays(1) }
    $xmlTarefa = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Backup diario das pastas deste computador para a OCI (backup-oci.ps1).</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$($primeira.ToString("s"))</StartBoundary>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$Destino\backup-oci.ps1" -Backup</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $arquivoTarefa = Join-Path $Destino "tarefa.xml"
    [IO.File]::WriteAllText($arquivoTarefa, $xmlTarefa, [Text.Encoding]::Unicode)
    & schtasks.exe /create /tn $NomeTarefa /xml $arquivoTarefa /ru SYSTEM /f | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Instalacao "Falha ao criar a tarefa agendada '$NomeTarefa'." }
    Remove-Item -LiteralPath $arquivoTarefa

    Write-Host ""
    Write-Host "INSTALACAO CONCLUIDA" -ForegroundColor Green
    Write-Host "O backup roda todo dia as $Horario (tarefa '$NomeTarefa'). Se o computador estiver desligado"
    Write-Host "nesse horario, roda assim que for ligado. Logs em $Destino\logs."
    Write-Host "Guarde este arquivo ($Script) e uma copia dele no cofre de senhas, com a chave."
    Write-Host "Executado de novo como administrador, ele abre o menu: ver o backup, rodar agora, restaurar"
    Write-Host "e atualizar (opcao 4: pastas, horario e chave). Mudou pastas ou horario? Atualize a copia"
    Write-Host "do cofre. Roteiro em LEIA-ME.txt."
}

# Vigia das outras maquinas: _status.txt com mais de $DiasSemBackupParaAlerta dias gera
# _alertas/<maquina>.txt (e-mail), no maximo um por dia para cada maquina.
function Send-AlertaParadas {
    $linhas = @(& $rclone lsf $RaizBucket --config /notfound -q --max-depth 2 --files-only --use-server-modtime --format "tp" --separator ";" --include "*/_status.txt" --include "_alertas/*")
    if ($LASTEXITCODE -ne 0) { return }
    $agora = Get-Date
    $ultimos = @{}
    $avisos = @{}
    foreach ($linha in $linhas) {
        $partes = $linha.Split(";")
        if ($partes.Count -lt 2) { continue }
        $quando = [DateTime]::ParseExact($partes[0], "yyyy-MM-dd HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
        if ($partes[1] -like "_alertas/*") { $avisos[$partes[1]] = $quando } else { $ultimos[$partes[1].Split("/")[0]] = $quando }
    }
    foreach ($maquina in @($ultimos.Keys)) {
        $aviso = "_alertas/$maquina.txt"
        if ($ultimos[$maquina] -ge $agora.AddDays(-$DiasSemBackupParaAlerta)) { continue }
        if ($avisos.ContainsKey($aviso) -and $avisos[$aviso] -ge $agora.AddHours(-20)) { continue }
        $texto = Join-Path $logDir "alerta.txt"
        Set-Content -LiteralPath $texto -Encoding ASCII -Value ("{0} sem backup desde {1:yyyy-MM-dd HH:mm} (detectado por {2})" -f $maquina, $ultimos[$maquina], $Servidor)
        & $rclone copyto $texto "$RaizBucket/$aviso" --config /notfound -q
    }
}

# Compartilhamento criado depois da escolha das pastas e fora do backup: aviso no log a cada
# backup e um e-mail (_alertas/) por compartilhamento. Os vistos na escolha nao avisam.
function Test-CompartilhamentosNovos {
    $conhecidos = @()
    $arquivoConhecidos = Join-Path $Base "compartilhamentos.txt"
    if (Test-Path -LiteralPath $arquivoConhecidos) { $conhecidos = @([IO.File]::ReadAllLines($arquivoConhecidos)) }
    $avisados = @()
    $arquivoAvisados = Join-Path $logDir "compartilhamentos-avisados.txt"
    if (Test-Path -LiteralPath $arquivoAvisados) { $avisados = @([IO.File]::ReadAllLines($arquivoAvisados)) }
    $novos = @()
    foreach ($compartilhamento in @(Get-Compartilhamentos)) {
        if ($conhecidos -contains $compartilhamento.Caminho) { continue }
        if (@(@($Pastas) | Where-Object { Test-Dentro $compartilhamento.Caminho (Format-Caminho $_) }).Count -gt 0) { continue }
        Write-Log ("Aviso: compartilhamento fora do backup: \\{0}\{1} ({2}); para incluir, use a opcao 4 do menu" -f $env:COMPUTERNAME, $compartilhamento.Nome, $compartilhamento.Caminho)
        if ($avisados -notcontains $compartilhamento.Caminho) { $novos += $compartilhamento }
    }
    if ($novos.Count -eq 0) { return }
    $texto = Join-Path $logDir "alerta.txt"
    [IO.File]::WriteAllLines($texto, [string[]]@($novos | ForEach-Object { "Compartilhamento fora do backup em {0}: \\{1}\{2} ({3})" -f $Servidor, $env:COMPUTERNAME, $_.Nome, $_.Caminho }), (New-Object Text.UTF8Encoding $false))
    & $rclone copyto $texto "$RaizBucket/_alertas/$Servidor-compartilhamento-novo.txt" --config /notfound -q
    if ($LASTEXITCODE -eq 0) {
        [IO.File]::AppendAllText($arquivoAvisados, ((@($novos | ForEach-Object { $_.Caminho }) -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
    }
}

# Pastas que ja passaram pelo backup (_pastas.txt no bucket): a restauracao lista tambem as que
# sairam da configuracao, e funciona num servidor novo com uma copia antiga deste arquivo.
function Get-PastasNoBucket([string]$Rclone, [string]$Pasta) {
    $existe = @(& $Rclone lsf "$RaizBucket/" --config /notfound -q --max-depth 2 --files-only --include "/$Servidor/_pastas.txt")
    if ($LASTEXITCODE -ne 0 -or $existe.Count -eq 0) { return @() }
    $local = Join-Path $Pasta "pastas-bucket.txt"
    & $Rclone copyto "$Remoto/_pastas.txt" $local --config /notfound -q
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $local)) { return @() }
    $lista = @([IO.File]::ReadAllLines($local) | ForEach-Object { Format-Caminho $_ } | Where-Object { $_ })
    Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
    return $lista
}

function Update-PastasNoBucket {
    $todas = @(@($Pastas) | ForEach-Object { Format-Caminho $_ } | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    foreach ($pasta in @(Get-PastasNoBucket $rclone $logDir)) { if ($todas -notcontains $pasta) { $todas += $pasta } }
    $arquivo = Join-Path $logDir "pastas.txt"
    [IO.File]::WriteAllLines($arquivo, [string[]]$todas, (New-Object Text.UTF8Encoding $false))
    & $rclone copyto $arquivo "$Remoto/_pastas.txt" --config /notfound -q
    if ($LASTEXITCODE -ne 0) { Write-Log "Aviso: falha ao enviar a lista de pastas (_pastas.txt) ao bucket" }
}

# Sombra (VSS) de cada volume das pastas: copia ate arquivo aberto. Sem VSS (servico parado,
# sem espaco para a sombra), copia direto, e arquivos travados falham como antes.
function New-Sombras([string[]]$Lista, [string]$Pasta) {
    $sombras = @{}
    Remove-Sombras $Pasta
    New-Item -ItemType Directory -Force -Path $Pasta | Out-Null
    foreach ($volume in @($Lista | ForEach-Object { [IO.Path]::GetPathRoot($_).ToUpper() } | Select-Object -Unique)) {
        try {
            $criada = ([WMIClass]"root\cimv2:Win32_ShadowCopy").Create($volume, "ClientAccessible")
            if ($criada.ReturnValue -ne 0) { throw "codigo $($criada.ReturnValue)" }
            Add-Content -LiteralPath (Join-Path $Pasta "sombras.txt") -Value $criada.ShadowID
            $sombra = Get-WmiObject Win32_ShadowCopy -Filter "ID='$($criada.ShadowID)'"
            $atalho = Join-Path $Pasta $volume.Substring(0, 1)
            & cmd.exe /c "mklink /d `"$atalho`" `"$($sombra.DeviceObject)\`" >nul 2>&1"
            if (-not (Test-Path -LiteralPath $atalho)) { throw "atalho para a sombra nao foi criado" }
            $sombras[$volume] = $atalho
            Write-Log "VSS: $volume lido de uma sombra (inclui arquivos abertos)"
        } catch {
            Write-Log "Aviso: VSS indisponivel em $volume ($($_.Exception.Message)); copia direta, arquivos travados falham"
        }
    }
    return $sombras
}

function Remove-Sombras([string]$Pasta) {
    if (-not (Test-Path -LiteralPath $Pasta)) { return }
    # rmdir sem /s apaga so o atalho, nunca o conteudo da sombra.
    Get-ChildItem -LiteralPath $Pasta | Where-Object { $_.PSIsContainer } | ForEach-Object { & cmd.exe /c "rmdir `"$($_.FullName)`" >nul 2>&1" }
    $registro = Join-Path $Pasta "sombras.txt"
    if (Test-Path -LiteralPath $registro) {
        foreach ($id in @(Get-Content -LiteralPath $registro)) {
            Get-WmiObject Win32_ShadowCopy -Filter "ID='$id'" | ForEach-Object { $_.Delete() }
        }
        Remove-Item -LiteralPath $registro -Force
    }
}

function Get-OrigemSombra([string]$Origem, $Sombras) {
    $raiz = [IO.Path]::GetPathRoot($Origem).ToUpper()
    if (-not $Sombras.ContainsKey($raiz)) { return $Origem }
    $naSombra = (Join-Path $Sombras[$raiz] $Origem.Substring($raiz.Length)).TrimEnd('\')
    if (Test-Path -LiteralPath $naSombra) { return $naSombra }
    Write-Log "Aviso: $Origem nao encontrada na sombra; copia direta"
    return $Origem
}

function Invoke-Backup {
    $rclone = Join-Path $Base "rclone.exe"
    $logDir = Join-Path $Base "logs"
    $inicio = Get-Date
    $log = Join-Path $logDir ("backup-{0}.log" -f $inicio.ToString("yyyy-MM-dd_HHmm"))
    $falhas = 0
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    # Log com BOM antes do primeiro rclone: o PowerShell (opcao 1 do menu) le os acentos certos.
    if (-not (Test-Path -LiteralPath $log)) { [IO.File]::WriteAllBytes($log, [byte[]](0xEF, 0xBB, 0xBF)) }

    # Mesmo formato de data do rclone.
    function Write-Log([string]$Mensagem) {
        Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format "yyyy/MM/dd HH:mm:ss"), $Mensagem) -Encoding UTF8
    }

    try {
        $chave = Read-Chave (Join-Path $Base "chave.dat")
    } catch {
        Write-Log "ERRO ao ler a chave ($($_.Exception.Message)): execute o instalador de novo"
        exit 1
    }

    # Backup atrasado: logo depois de ligar o computador, a rede pode nao estar pronta.
    $caminho = Get-Caminho
    $espera = 0
    $conectado = Test-Porta $caminho.Teste 443
    while (-not $conectado -and $espera -lt $EsperaRedeMinutos) {
        Start-Sleep -Seconds 60
        $espera++
        $caminho = Get-Caminho
        $conectado = Test-Porta $caminho.Teste 443
    }
    if (-not $conectado) { Write-Log ("Sem conexao com {0} apos {1} min de espera" -f $caminho.Teste, $espera) }
    elseif ($espera -gt 0) { Write-Log ("Conexao com a nuvem disponivel apos {0} min de espera" -f $espera) }
    $caminho = Confirm-Caminho $caminho $chave $rclone $log
    if ($caminho.VpnRecusada) { Write-Log "Aviso: a VPN responde, mas a nuvem recusou o acesso por ela (erro acima); backup pela internet" }

    $opcoes = @("--config", "/notfound", "--log-file", $log, "--log-level", "INFO",
        "--retries", "3", "--low-level-retries", "10", "--stats", "10m", "--stats-log-level", "NOTICE")
    if ($LimiteBanda) { $opcoes += @("--bwlimit", $LimiteBanda) }
    foreach ($padrao in @($Exclusoes)) { if ($padrao) { $opcoes += @("--exclude", $padrao) } }

    try {
        Write-Log ("Inicio do backup de {0} ({1} pasta(s)), caminho: {2}" -f $Servidor, @($Pastas).Count, $caminho.Nome)
        $sombras = New-Sombras @($Pastas) (Join-Path $Base "vss")

        # Pasta em que o rclone falhar e tentada de novo, ate 3 vezes no total.
        $pendentes = @($Pastas)
        for ($tentativa = 1; $tentativa -le 3 -and $pendentes.Count -gt 0; $tentativa++) {
            if ($tentativa -gt 1) {
                Write-Log ("Nova tentativa em {0} min para {1} pasta(s)" -f $IntervaloNovaTentativaMinutos, $pendentes.Count)
                for ($minuto = 0; $minuto -lt $IntervaloNovaTentativaMinutos; $minuto++) { Start-Sleep -Seconds 60 }
            }
            $falharam = @()
            foreach ($pasta in $pendentes) {
                # Sem barra final: "D:\Pasta\" chegaria ao rclone com a aspa escapada.
                $origem = $pasta.TrimEnd('\')
                if ($origem -match '^[A-Za-z]:$') { $origem += '\' }
                if (-not (Test-Path -LiteralPath $origem)) {
                    $falhas++
                    Write-Log "ERRO pasta nao encontrada: $pasta"
                    continue
                }
                # D:\Dados\Clinica -> <servidor>/arquivos/D/Dados/Clinica
                $relativo = $pasta.TrimEnd('\') -replace '^([A-Za-z]):', '$1' -replace '\\', '/'
                $alvo = "$Remoto/arquivos/$relativo"
                Write-Log "Copiando $origem -> $alvo"
                $origem = Get-OrigemSombra $origem $sombras
                & $rclone copy $origem $alvo $opcoes
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "ERRO rclone terminou com codigo $LASTEXITCODE em $origem (tentativa $tentativa)"
                    $falharam += $pasta
                }
            }
            $pendentes = $falharam
        }
        $falhas += $pendentes.Count
    } catch {
        $falhas++
        Write-Log "ERRO inesperado: $($_.Exception.Message)"
    } finally {
        try { Remove-Sombras (Join-Path $Base "vss") } catch { Write-Log "Aviso: falha ao apagar as sombras (VSS): $($_.Exception.Message)" }
    }
    try { Test-CompartilhamentosNovos } catch { Write-Log "Aviso: falha ao verificar os compartilhamentos: $($_.Exception.Message)" }
    try { Update-PastasNoBucket } catch { Write-Log "Aviso: falha ao atualizar a lista de pastas no bucket: $($_.Exception.Message)" }

    $minutos = [int]((Get-Date) - $inicio).TotalMinutes
    if ($falhas -eq 0) { $status = "OK" } else { $status = "ERRO ($falhas falha(s))" }
    Write-Log "Fim: $status em $minutos min"

    $arquivoStatus = Join-Path $logDir "ultimo-status.txt"
    Set-Content -LiteralPath $arquivoStatus -Encoding UTF8 -Value @(
        "status: $status",
        "servidor: $Servidor ($env:COMPUTERNAME)",
        "caminho: $($caminho.Nome)",
        "inicio: $($inicio.ToString('yyyy-MM-dd HH:mm'))",
        "duracao_min: $minutos",
        "log: $(Split-Path -Leaf $log)"
    )
    # Com erro, _alertas/<servidor>.txt dispara o e-mail de alerta (03-storage).
    & $rclone copyto $log "$Remoto/_logs/$(Split-Path -Leaf $log)" --config /notfound -q
    $envio = $LASTEXITCODE
    & $rclone copyto $arquivoStatus "$Remoto/_status.txt" --config /notfound -q
    if ($envio -eq 0) { $envio = $LASTEXITCODE }
    if ($falhas -gt 0) { & $rclone copyto $arquivoStatus "$RaizBucket/_alertas/$Servidor.txt" --config /notfound -q }
    try { Send-AlertaParadas } catch { Write-Log "Aviso: falha ao verificar as outras maquinas: $($_.Exception.Message)" }
    if ($envio -ne 0) {
        $falhas++
        Write-Log "ERRO ao enviar o log ou o status ao bucket"
    }

    try {
        Get-ChildItem -Path $logDir -Filter "backup-*.log" |
            Where-Object { $_.LastWriteTime -lt $inicio.AddDays(-$RetencaoLogsDias) } |
            Remove-Item -Force
    } catch {
        Write-Log "Aviso: falha ao limpar logs antigos: $($_.Exception.Message)"
    }

    if ($falhas -gt 0) { exit 1 }
    exit 0
}

function Show-Status {
    $logDir = Join-Path $Destino "logs"
    $arquivoStatus = Join-Path $logDir "ultimo-status.txt"
    Write-Host ""
    if (-not (Test-Path -LiteralPath $arquivoStatus)) {
        Write-Host "  Nenhum backup terminou ainda neste computador." -ForegroundColor Yellow
    } else {
        Get-Content -LiteralPath $arquivoStatus | ForEach-Object { Write-Host "  $_" }
        $idade = (Get-Date) - (Get-Item -LiteralPath $arquivoStatus).LastWriteTime
        if ($idade.TotalDays -gt 2) { Write-Host ("  ATENCAO: o ultimo backup terminou ha {0} dias." -f [int]$idade.TotalDays) -ForegroundColor Red }
        $ultimo = Get-ChildItem -Path $logDir -Filter "backup-*.log" | Sort-Object Name | Select-Object -Last 1
        if ($ultimo) {
            $avisos = @(Get-Content -LiteralPath $ultimo.FullName | Where-Object { $_ -cmatch "ERRO|Aviso" } | Select-Object -Last 10)
            if ($avisos.Count -gt 0) {
                Write-Host "  Erros e avisos do ultimo backup ($($ultimo.Name)):" -ForegroundColor Yellow
                $avisos | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            } else {
                Write-Host "  Sem erros nem avisos no ultimo backup." -ForegroundColor Green
            }
        }
    }
    & cmd.exe /c "schtasks /query /tn `"$NomeTarefa`" >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { Write-Host "  ATENCAO: a tarefa agendada '$NomeTarefa' nao existe. Use a opcao 4." -ForegroundColor Red; return }
    [xml]$tarefa = (& schtasks.exe /query /tn $NomeTarefa /xml) -join "`n"
    Write-Host ("  Agendado todo dia as {0:HH:mm} (tarefa '{1}')." -f [DateTime]::Parse($tarefa.Task.Triggers.CalendarTrigger.StartBoundary), $NomeTarefa)
    # Estado 4 = em execucao, pelo Agendador (nao depende do idioma do Windows).
    try {
        $agendador = New-Object -ComObject Schedule.Service
        $agendador.Connect()
        if ($agendador.GetFolder("\").GetTask($NomeTarefa).State -eq 4) {
            Write-Host "  Backup em andamento agora: o resultado acima e o do anterior. Veja de novo quando terminar." -ForegroundColor Yellow
        }
    } catch { }
}

function Start-BackupAgora {
    & cmd.exe /c "schtasks /run /tn `"$NomeTarefa`" >nul 2>&1"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK  backup iniciado em segundo plano. O resultado aparece na opcao 1 quando terminar." -ForegroundColor Green
    } else {
        Write-Host "  ERRO: nao foi possivel iniciar a tarefa '$NomeTarefa'. Use a opcao 4." -ForegroundColor Red
    }
}

# Pasta (ou parte dela) do backup deste computador, na versao mais recente ou como estava
# numa data, para a pasta escolhida.
function Restore-Backup {
    $rclone = Join-Path $Destino "rclone.exe"
    $caminho = Confirm-Caminho (Get-Caminho) (Read-Chave (Join-Path $Destino "chave.dat")) $rclone
    if ($caminho.VpnRecusada) { Write-Host "  Aviso: a nuvem recusou o acesso pela VPN (erro acima); usando a internet." -ForegroundColor Yellow }
    # As configuradas e as que ja passaram pelo backup, inclusive as que sairam da configuracao.
    $lista = @(Get-PastasConfiguradas)
    $antigas = @()
    foreach ($pasta in @(Get-PastasNoBucket $rclone (Join-Path $Destino "logs"))) {
        if ($lista -notcontains $pasta) { $lista += $pasta; $antigas += $pasta }
    }
    if ($lista.Count -eq 0) { Write-Host "  Nenhuma pasta no backup deste computador." -ForegroundColor Yellow; return }
    $opcoes = @()
    for ($i = 0; $i -lt $lista.Count; $i++) {
        $texto = $lista[$i]
        if ($antigas -contains $lista[$i]) { $texto += "  (fora da configuracao atual)" }
        $opcoes += @{ Tecla = [string]($i + 1); Texto = $texto }
    }
    $opcoes += @{ Tecla = "0"; Texto = "Voltar ao menu" }
    $resposta = Select-Opcao ("Pastas no backup de {0}:" -f $Servidor) $opcoes
    if ($resposta -eq "0") { return }
    $numero = 0
    if (-not [int]::TryParse($resposta, [ref]$numero) -or $numero -lt 1 -or $numero -gt $lista.Count) {
        Write-Host "  Numero de pasta invalido." -ForegroundColor Red
        return
    }
    $pasta = $lista[$numero - 1].TrimEnd('\')
    $parte = (Read-Resposta "Subpasta ou arquivo dentro dela, ex.: Financeiro\2026 (Enter = a pasta inteira)").Trim('\')
    $quando = Read-Resposta "Voltar no tempo: AAAA-MM-DD ou AAAA-MM-DD HH:MM (Enter = versao mais recente)"
    $opcoes = @("--config", "/notfound", "--retries", "3", "--low-level-retries", "10")
    if ($quando) {
        $data = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($quando, [string[]]@("yyyy-MM-dd HH:mm", "yyyy-MM-dd"), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$data)) {
            Write-Host "  Data invalida: use AAAA-MM-DD ou AAAA-MM-DD HH:MM." -ForegroundColor Red
            return
        }
        # So a data: como estava no fim do dia, depois do backup da noite.
        if ($quando.Length -eq 10) { $data = $data.AddDays(1).AddSeconds(-1) }
        $opcoes += @("--s3-version-at", $data.ToString("yyyy-MM-dd HH:mm:ss"))
    }
    $padrao = Join-Path "C:\Restaurado-OCI" (Get-Date -Format "yyyy-MM-dd_HHmmss")
    $destinoRestauracao = Read-Resposta "Pasta de destino (Enter = $padrao)"
    if (-not $destinoRestauracao) { $destinoRestauracao = $padrao }
    $destinoRestauracao = $destinoRestauracao.TrimEnd('\')
    $origem = "$Remoto/arquivos/" + ($pasta -replace '^([A-Za-z]):', '$1' -replace '\\', '/')
    if ($parte) { $origem += "/" + ($parte -replace '\\', '/') }

    $json = (& $rclone size $origem $opcoes --json) -join ""
    $codigo = $LASTEXITCODE
    $quantidade = -1
    $bytes = 0
    if ($json -match '"count":(\d+)') { $quantidade = [int64]$Matches[1] }
    if ($json -match '"bytes":(\d+)') { $bytes = [int64]$Matches[1] }
    if ($codigo -ne 0 -or $quantidade -lt 0) { Write-Host "  Nao foi possivel ler o backup nesse caminho (detalhes acima)." -ForegroundColor Red; return }
    if ($quantidade -eq 0) { Write-Host "  Nada encontrado nesse caminho e data." -ForegroundColor Yellow; return }
    foreach ($p in @($Pastas)) {
        if (($destinoRestauracao + "\").StartsWith($p.TrimEnd('\') + "\", [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "  ATENCAO: o destino fica dentro de $p; arquivos com o mesmo nome serao substituidos." -ForegroundColor Yellow
        }
    }
    $pergunta = "Restaurar {0} arquivo(s), {1:N1} MB, para {2}? (S/N)" -f $quantidade, ($bytes / 1MB), $destinoRestauracao
    if ((Read-Resposta $pergunta) -notmatch '^[sS]') { Write-Host "  Cancelado."; return }
    $logRestauracao = Join-Path $Destino ("logs\restauracao-{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
    & $rclone copy $origem $destinoRestauracao $opcoes --progress --log-file $logRestauracao --log-level INFO
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK  restaurado em $destinoRestauracao. Confira antes de substituir os originais." -ForegroundColor Green
    } else {
        Write-Host "  ERRO na restauracao (codigo $LASTEXITCODE). Detalhes em $logRestauracao" -ForegroundColor Red
    }
}

function Show-Menu {
    return (Select-Opcao ("Backup OCI ja instalado neste computador ({0})." -f $Servidor) @(
            @{ Tecla = "1"; Texto = "Ver o ultimo backup" },
            @{ Tecla = "2"; Texto = "Rodar o backup agora" },
            @{ Tecla = "3"; Texto = "Restaurar arquivos" },
            @{ Tecla = "4"; Texto = "Atualizar a instalacao (escolher pastas e horario, trocar a chave)" },
            @{ Tecla = "0"; Texto = "Sair" }))
}

# Bloco de edicao como esta no arquivo agora: pode ter sido editado com o menu aberto.
function Get-BlocoEdicao {
    return [regex]::Match((Read-TextoScript $Script), '(?s)# =+ EDITE SO ESTE BLOCO =+\r?\n(.*?)\r?\n# =+\r?\n').Groups[1].Value
}

if ($Backup) { Invoke-Backup } else {
    try {
        Test-Administrador
        if (-not (Test-Path -LiteralPath (Join-Path $Destino "backup-oci.ps1"))) { Install-Backup } else {
            # Volta ao menu depois de cada opcao; so o 0 sai. Sem teclado (entrada redirecionada),
            # 20 respostas invalidas seguidas encerram, para nao ficar em loop.
            $invalidas = 0
            # Bloco de edicao relido neste nivel, para valer no script todo, como na abertura.
            $recarregar = {
                . ([ScriptBlock]::Create((Get-BlocoEdicao)))
                if (-not $Servidor) { $Servidor = $env:COMPUTERNAME.ToLower() -replace "[^a-z0-9-]", "-" }
                $Remoto = "$RaizBucket/$Servidor"
            }
            :menu while (($opcao = Show-Menu) -ne "0") {
                try {
                    switch ($opcao) {
                        "1" { $invalidas = 0; Show-Status }
                        "2" { $invalidas = 0; Start-BackupAgora }
                        "3" { $invalidas = 0; Restore-Backup }
                        "4" {
                            $invalidas = 0
                            . $recarregar
                            Install-Backup
                            # A escolha de pastas e horario pode ter regravado o arquivo.
                            . $recarregar
                        }
                        default {
                            Write-Host "  Opcao invalida: digite um numero de 0 a 4." -ForegroundColor Yellow
                            if (++$invalidas -ge 20) { break menu }
                        }
                    }
                } catch { Write-Host ("  ERRO: {0}" -f $_.Exception.Message) -ForegroundColor Red }
            }
        }
    } catch { Stop-Instalacao $_.Exception.Message }
}
