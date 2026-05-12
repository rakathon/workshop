# Rakuten Claude Code Setup - Windows
# Authenticates via Okta PKCE, installs Git/VS Code/Claude Code extension,
# and writes %USERPROFILE%\.claude\settings.json.
#
# Run from PowerShell:  Set-ExecutionPolicy Bypass -Scope Process -Force; .\setup.ps1

$ErrorActionPreference = 'Stop'

$OktaIssuer  = "https://rakuten.okta.com/oauth2/ausxr4nv1gcTtBswT357"
$ClientId    = "0oa1hk5jgg1Oz3zDm358"
$RedirectUri = "https://developer.ai.public.rakuten-it.com/callback"
$Scopes      = "openid email profile"
$PatUrl      = "https://developer-backend.ai.public.rakuten-it.com/projects/540fe463-79a3-4b91-894c-ec24c1012bd1/claude-code-aws-bedrock/config"

$PollSecs    = 2
$TimeoutSecs = 300
$DebugPort   = 9229

# ── UI helpers ─────────────────────────────────────────────────────────────────

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor White
    Write-Host "  ║       Rakuten Claude Code Setup (Windows)            ║" -ForegroundColor White
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor White
    Write-Host ""
}

function Write-Step($num, $label) {
    Write-Host "  [$num] $label" -ForegroundColor Cyan
}

function Write-StepDone($num, $label) {
    Write-Host "  [$num] $label" -ForegroundColor Green
}

function Write-StepActive($num, $label) {
    Write-Host "  [$num] $label" -ForegroundColor Yellow
}

function Write-Info($msg) {
    Write-Host "      $msg" -ForegroundColor DarkGray
}

function Write-Warn($msg) {
    Write-Host ""
    Write-Host "  ⚠  $msg" -ForegroundColor Yellow
}

function Exit-Error($msg) {
    Write-Host ""
    Write-Host "  ✗  Error: $msg" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ── PKCE helpers ───────────────────────────────────────────────────────────────

function New-PkceVerifier {
    $bytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) -replace '[+/=]', '' | ForEach-Object { $_.Substring(0, [Math]::Min(64, $_.Length)) }
}

function Get-PkceChallenge($verifier) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash   = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    return [Convert]::ToBase64String($hash).TrimEnd('=') -replace '\+', '-' -replace '/', '_'
}

function ConvertTo-UrlEncoded($str) {
    return [Uri]::EscapeDataString($str)
}

$amp = [char]38   # '&' - avoids PS5.1 parser rejection of literal & in strings

function Find-ChromiumExe {
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    Exit-Error "No Chromium-based browser found. Microsoft Edge is pre-installed on Windows 10/11 - please ensure it is present."
}

# ── header ─────────────────────────────────────────────────────────────────────

Write-Header

Write-Host "  This script will:"
Write-Step "1" "Sign you in with your Rakuten account"
Write-Step "2" "Install Git, VS Code, Claude Code extension, and plugins"
Write-Step "3" "Configure Claude Code automatically"
Write-Step "4" "Apply Claude Desktop registry settings"
Write-Host ""

# ── step 1: sign in ────────────────────────────────────────────────────────────

Write-StepActive "1" "Sign in with your Rakuten account"
Write-Info "Opening browser - log in and complete MFA..."
Write-Host ""

$Verifier  = New-PkceVerifier
$Challenge = Get-PkceChallenge $Verifier
$StateBytes = New-Object byte[] 16
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($StateBytes)
$State = ([System.BitConverter]::ToString($StateBytes) -replace '-', '').ToLower()

$AuthQuery = @(
    "response_type=code",
    "client_id=$ClientId",
    "redirect_uri=$(ConvertTo-UrlEncoded $RedirectUri)",
    "scope=$(ConvertTo-UrlEncoded $Scopes)",
    "state=$State",
    "code_challenge=$Challenge",
    "code_challenge_method=S256"
) -join $amp
$AuthUrl = "$OktaIssuer/v1/authorize?$AuthQuery"

$BrowserExe  = Find-ChromiumExe
$TempProfile = Join-Path $env:TEMP "okta-login-$([System.Guid]::NewGuid().ToString('N'))"

$BrowserProc = Start-Process -FilePath $BrowserExe -ArgumentList @(
    "--remote-debugging-port=$DebugPort"
    "--remote-allow-origins=*"
    "--user-data-dir=`"$TempProfile`""
    "--no-first-run"
    "--no-default-browser-check"
    "`"$AuthUrl`""
) -PassThru

# Wait for CDP to become available
$CdpReady = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    try {
        $null = Invoke-RestMethod "http://localhost:$DebugPort/json/version" -ErrorAction Stop
        $CdpReady = $true; break
    } catch {}
}
if (-not $CdpReady) {
    $BrowserProc | Stop-Process -Force -ErrorAction SilentlyContinue
    Exit-Error "Browser did not expose CDP on port $DebugPort within 20 seconds."
}

$Elapsed = 0
$Code    = $null

while ($Elapsed -lt $TimeoutSecs) {
    Start-Sleep -Seconds $PollSecs
    $Elapsed += $PollSecs
    try {
        $Tabs = Invoke-RestMethod "http://localhost:$DebugPort/json/list" -ErrorAction SilentlyContinue
        foreach ($Tab in $Tabs) {
            if ($Tab.url -like "*developer.ai.public.rakuten-it.com/callback*" -and $Tab.url -like "*code=*") {
                $Uri      = [System.Uri]$Tab.url
                $Query    = [System.Web.HttpUtility]::ParseQueryString($Uri.Query)
                $Code     = $Query["code"]
                $GotState = $Query["state"]
                if ($GotState -ne $State) {
                    $BrowserProc | Stop-Process -Force -ErrorAction SilentlyContinue
                    Exit-Error "State mismatch - possible CSRF. Aborting."
                }
                break
            }
        }
    } catch {}
    if ($Code) { break }
    Write-Info "...waiting for sign-in... (${Elapsed}s)"
}

$BrowserProc | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $TempProfile -ErrorAction SilentlyContinue

if (-not $Code) { Exit-Error "Timed out after ${TimeoutSecs}s. Did you complete the sign-in?" }

Write-Info "Exchanging token..."

try {
    $TokenResponse = Invoke-RestMethod -Method Post -Uri "$OktaIssuer/v1/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{
            grant_type    = "authorization_code"
            client_id     = $ClientId
            redirect_uri  = $RedirectUri
            code          = $Code
            code_verifier = $Verifier
        }
} catch {
    Exit-Error "Token exchange failed: $_"
}

$AccessToken = $TokenResponse.access_token
if ([string]::IsNullOrEmpty($AccessToken)) { Exit-Error "No access_token in response." }

Write-Info "Fetching access key..."

try {
    $PatResponse = Invoke-RestMethod `
        -Method Post `
        -Uri $PatUrl `
        -Headers @{
            Authorization = "Bearer $AccessToken"
            Accept        = "application/json"
            Origin        = "https://developer.ai.public.rakuten-it.com"
            Referer       = "https://developer.ai.public.rakuten-it.com/"
        }
} catch {
    Exit-Error "PAT request failed: $_"
}

$Pat = $PatResponse.secret_key
if ([string]::IsNullOrEmpty($Pat)) { Exit-Error "No secret_key in response." }

Write-Host ""
Write-StepDone "1" "Signed in successfully"

# ── step 2: install Git, VS Code, Claude Code extension ───────────────────────

Write-StepActive "2" "Install Git, VS Code, Claude Code extension, and plugins"
Write-Host ""

# Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Info "Downloading Git for Windows..."
    $GitInstaller = "$env:TEMP\git-setup.exe"
    $GitUrl = "https://github.com/git-for-windows/git/releases/latest/download/Git-64-bit.exe"
    try {
        Invoke-WebRequest -Uri $GitUrl -OutFile $GitInstaller -UseBasicParsing
        Write-Info "Installing Git (silent)..."
        Start-Process -FilePath $GitInstaller `
            -ArgumentList "/VERYSILENT", "/NORESTART", "/NOCANCEL", "/SP-", "/CLOSEAPPLICATIONS", "/RESTARTAPPLICATIONS" `
            -Wait
        Remove-Item $GitInstaller -Force -ErrorAction SilentlyContinue
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
        Write-Info "Git installed."
    } catch {
        Write-Warn "Could not install Git automatically: $_. Install manually from https://git-scm.com"
    }
} else {
    Write-Info "Git already installed ($(git --version))."
}

# VS Code
if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
    Write-Info "Downloading VS Code..."
    $VsCodeInstaller = "$env:TEMP\vscode-setup.exe"
    $VsCodeUrl = "https://update.code.visualstudio.com/latest/win32-x64-user/stable"
    try {
        Invoke-WebRequest -Uri $VsCodeUrl -OutFile $VsCodeInstaller -UseBasicParsing
        Write-Info "Installing VS Code (silent)..."
        Start-Process -FilePath $VsCodeInstaller `
            -ArgumentList "/VERYSILENT", "/NORESTART", "/MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,addtopath" `
            -Wait
        Remove-Item $VsCodeInstaller -Force -ErrorAction SilentlyContinue
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
        Write-Info "VS Code installed."
    } catch {
        Write-Warn "Could not install VS Code automatically: $_. Install manually from https://code.visualstudio.com"
    }
} else {
    Write-Info "VS Code already installed."
}

# Claude Code CLI
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Info "Installing Claude Code CLI..."
    try {
        irm https://claude.ai/install.ps1 | iex
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
    } catch {
        Write-Warn "Could not install Claude Code CLI automatically. Visit https://claude.ai/install for instructions."
    }
} else {
    Write-Info "Claude Code CLI already installed."
}

# Claude Code extension
if (Get-Command code -ErrorAction SilentlyContinue) {
    $Extensions = & code --list-extensions 2>$null
    if ($Extensions -notmatch "anthropic\.claude-code") {
        Write-Info "Installing Claude Code extension..."
        try {
            & code --install-extension anthropic.claude-code --force
        } catch {
            Write-Warn "Could not install Claude Code extension automatically. Install 'Claude Code' from the VS Code Marketplace."
        }
    } else {
        Write-Info "Claude Code extension already installed."
    }
} else {
    Write-Warn "VS Code CLI 'code' not on PATH - skipping extension install. Open VS Code and install 'Claude Code' from the Marketplace."
}

Write-Host ""
Write-StepDone "2" "Git, VS Code, and Claude Code extension ready"

# ── step 3: write settings.json ───────────────────────────────────────────────

Write-StepActive "3" "Configuring Claude Code"
Write-Info "Writing settings.json..."

$SettingsDir  = "$env:USERPROFILE\.claude"
$SettingsFile = "$SettingsDir\settings.json"

if (!(Test-Path $SettingsDir)) {
    New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null
}

$EnvBlock = [ordered]@{
    ANTHROPIC_BEDROCK_BASE_URL   = "https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1"
    AWS_BEARER_TOKEN_BEDROCK     = $Pat
    CLAUDE_CODE_USE_BEDROCK      = "1"
    CLAUDE_CODE_SKIP_BEDROCK_AUTH = "1"
    CLAUDE_CODE_ENABLE_TELEMETRY = "1"
    OTEL_METRICS_EXPORTER        = "otlp"
    OTEL_LOGS_EXPORTER           = "otlp"
    OTEL_EXPORTER_OTLP_PROTOCOL  = "http/protobuf"
    OTEL_EXPORTER_OTLP_ENDPOINT  = "https://api.ai.public.rakuten-it.com/otel"
    OTEL_EXPORTER_OTLP_HEADERS   = "Authorization=$Pat"
}

if (Test-Path $SettingsFile) {
    # Merge: load existing JSON and overwrite only our keys
    try {
        $Existing = Get-Content $SettingsFile -Raw | ConvertFrom-Json
    } catch {
        $Existing = [PSCustomObject]@{}
    }
    if ($null -eq $Existing.env) {
        $Existing | Add-Member -NotePropertyName "env" -NotePropertyValue ([PSCustomObject]@{})
    }
    foreach ($key in $EnvBlock.Keys) {
        if ($Existing.env.PSObject.Properties.Name -contains $key) {
            $Existing.env.$key = $EnvBlock[$key]
        } else {
            $Existing.env | Add-Member -NotePropertyName $key -NotePropertyValue $EnvBlock[$key]
        }
    }
    $Existing | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsFile -Encoding UTF8
} else {
    # Fresh write
    [PSCustomObject]@{ env = $EnvBlock } | ConvertTo-Json -Depth 10 |
        Set-Content -Path $SettingsFile -Encoding UTF8
}

Write-Host ""
Write-StepDone "3" "Claude Code configured"

# ── step 3b: install Claude plugins (needs settings.json to be present) ───────

Write-StepActive "3" "Installing Claude plugins"
Write-Host ""

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Info "Adding claude-plugins-official registry..."
    try {
        & claude plugin add anthropics/claude-plugins-official 2>$null
    } catch {
        Write-Warn "Could not add plugin registry. Run manually: claude plugin add anthropics/claude-plugins-official"
    }

    Write-Info "Installing skill-creator plugin..."
    try {
        & claude plugin install skill-creator@claude-plugins-official --scope user 2>$null
    } catch {
        Write-Warn "Could not install skill-creator. Run manually: claude plugin install skill-creator@claude-plugins-official --scope user"
    }
} else {
    Write-Warn "'claude' CLI not found - skipping plugin install. After installing Claude Code, run:`n        claude plugin add anthropics/claude-plugins-official`n        claude plugin install skill-creator@claude-plugins-official --scope user"
}

Write-Host ""
Write-StepDone "3" "Claude plugins installed"

# ── step 4: apply Claude Desktop registry settings ────────────────────────────

$RegTemplate = @"
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\SOFTWARE\Policies\Claude]
"coworkEgressAllowedHosts"="[`"*`"]"
"inferenceProvider"="bedrock"
"inferenceBedrockRegion"="us-east-1"
"inferenceBedrockBearerToken"="{{BEARER_TOKEN}}"
"inferenceBedrockBaseUrl"="https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1"
"inferenceModels"="[{`"name`":`"us.anthropic.claude-sonnet-4-6`",`"supports1m`":true}]"
"managedMcpServers"="[{`"name`":`"playwright`",`"url`":`"https://agentgateway-mcp.shared-np.rr-it.com/mcp/playwright`",`"oauth`":true,`"transport`":`"http`"},{`"name`":`"atlassian`",`"url`":`"https://agentgateway-mcp.shared-np.rr-it.com/mcp/atlassian`",`"oauth`":true,`"transport`":`"http`"},{`"name`":`"monday.com`",`"url`":`"https://mcp.monday.com/sse`",`"oauth`":true,`"transport`":`"sse`"}]"
"@

Write-StepActive "4" "Apply Claude Desktop registry settings"
Write-Info "Preparing registry settings..."

$RegContent = $RegTemplate.Replace("{{BEARER_TOKEN}}", $Pat)

Write-Info "Applying registry settings (UAC prompt may appear)..."
$RegTmp = Join-Path $env:TEMP "Claude-$(New-Guid).reg"
try {
    [System.IO.File]::WriteAllText($RegTmp, $RegContent, [System.Text.Encoding]::Unicode)
    $result = Start-Process reg.exe -Verb RunAs -Wait -PassThru `
        -ArgumentList "import `"$RegTmp`""
    if ($result.ExitCode -ne 0) {
        Write-Warn "Registry import failed (exit $($result.ExitCode)) - you may need to run as Administrator."
    }
} catch {
    Write-Warn "Failed to apply registry settings: $_"
} finally {
    Remove-Item $RegTmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-StepDone "4" "Claude Desktop registry settings applied"

# ── summary ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║               Setup Complete!                        ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "      1. Open VS Code in your project folder" -ForegroundColor DarkGray
Write-Host '      2. Press Ctrl+Shift+P -> "Claude: Open Chat" to start coding' -ForegroundColor DarkGray
Write-Host ""
