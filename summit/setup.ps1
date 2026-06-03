# Rakuten Claude Code Setup - Windows (Summit)
# Authenticates via Okta PKCE, installs Claude Code CLI,
# and writes %USERPROFILE%\.claude\settings.json.
#
# Run from PowerShell: Set-ExecutionPolicy Bypass -Scope Process -Force; .\setup.ps1

$ErrorActionPreference = 'Stop'

$OktaIssuer  = "https://rakuten.okta.com/oauth2/ausxr4nv1gcTtBswT357"
$ClientId    = "0oa1hk5jgg1Oz3zDm358"
$RedirectUri = "https://developer.ai.public.rakuten-it.com/callback"
$Scopes      = "openid email profile"
$PatUrl      = "https://developer-backend.ai.public.rakuten-it.com/projects/540fe463-79a3-4b91-894c-ec24c1012bd1/claude-code-aws-bedrock/config"

$PollSecs    = 2
$TimeoutSecs = 300
$DebugPort   = 9229

# ── helpers ────────────────────────────────────────────────────────────────────

function Write-Ok($msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Run($msg)  { Write-Host "   ->   $msg" -ForegroundColor DarkGray }
function Write-Warn($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Exit-Error($msg) {
    Write-Host ""
    Write-Host "  [ERR] $msg" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ── PKCE helpers ───────────────────────────────────────────────────────────────

function New-PkceVerifier {
    $bytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) -replace '[+/=]', '' |
        ForEach-Object { $_.Substring(0, [Math]::Min(64, $_.Length)) }
}

function Get-PkceChallenge($verifier) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash   = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    return [Convert]::ToBase64String($hash).TrimEnd('=') -replace '\+', '-' -replace '/', '_'
}

function ConvertTo-UrlEncoded($str) { return [Uri]::EscapeDataString($str) }

$amp = [char]38

function Find-ChromiumExe {
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    Exit-Error "No Chromium-based browser found. Microsoft Edge is pre-installed on Windows 10/11."
}

# ── header ─────────────────────────────────────────────────────────────────────

Clear-Host
Write-Host ""
Write-Host "  Rakuten Claude Code Setup  (Windows)" -ForegroundColor White
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── step 1: okta sign-in ───────────────────────────────────────────────────────

Write-Run "Opening browser for Rakuten OKTA sign-in..."

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
                    Exit-Error "State mismatch — possible CSRF. Aborting."
                }
                break
            }
        }
    } catch {}
    if ($Code) { break }
    Write-Host "   ->   Waiting for sign-in... (${Elapsed}s)" -ForegroundColor DarkGray
}

$BrowserProc | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $TempProfile -ErrorAction SilentlyContinue

if (-not $Code) { Exit-Error "Timed out after ${TimeoutSecs}s. Did you complete sign-in?" }

Write-Run "Exchanging token..."

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

Write-Run "Fetching Rakuten AI access key..."

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
    Exit-Error "Access key request failed: $_"
}

$Pat = $PatResponse.secret_key
if ([string]::IsNullOrEmpty($Pat)) { Exit-Error "No secret_key in response." }

Write-Ok "Signed in successfully"

# ── step 2: install Claude Code CLI ───────────────────────────────────────────

Write-Run "Installing Claude Code CLI..."

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    try {
        irm https://claude.ai/install.ps1 | iex
        $LocalBin = "$env:USERPROFILE\.local\bin"
        $UserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        if ($UserPath -notlike "*$LocalBin*") {
            [System.Environment]::SetEnvironmentVariable("Path", "$UserPath;$LocalBin", "User")
        }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")
        Write-Ok "Claude Code CLI installed"
    } catch {
        Write-Warn "Could not install Claude Code CLI automatically. Visit https://claude.ai/install"
    }
} else {
    $ClaudeVersion = & claude --version 2>$null
    Write-Ok "Claude Code CLI already installed ($ClaudeVersion)"
}

# ── step 3: write settings.json ───────────────────────────────────────────────

Write-Run "Writing settings.json..."

$SettingsDir  = "$env:USERPROFILE\.claude"
$SettingsFile = "$SettingsDir\settings.json"

if (!(Test-Path $SettingsDir)) {
    New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null
}

$EnvBlock = [ordered]@{
    ANTHROPIC_BEDROCK_BASE_URL    = "https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1"
    AWS_BEARER_TOKEN_BEDROCK      = $Pat
    CLAUDE_CODE_USE_BEDROCK       = "1"
    CLAUDE_CODE_SKIP_BEDROCK_AUTH = "1"
    CLAUDE_CODE_ENABLE_TELEMETRY  = "1"
    OTEL_METRICS_EXPORTER         = "otlp"
    OTEL_LOGS_EXPORTER            = "otlp"
    OTEL_EXPORTER_OTLP_PROTOCOL   = "http/protobuf"
    OTEL_EXPORTER_OTLP_ENDPOINT   = "https://api.ai.public.rakuten-it.com/otel"
    OTEL_EXPORTER_OTLP_HEADERS    = "Authorization=$Pat"
}

if (Test-Path $SettingsFile) {
    try {
        $Existing = Get-Content $SettingsFile -Raw | ConvertFrom-Json
    } catch {
        $Existing = [PSCustomObject]@{}
    }
    if (-not ($Existing.PSObject.Properties.Name -contains "env")) {
        $Existing | Add-Member -NotePropertyName "env" -NotePropertyValue ([PSCustomObject]@{})
    }
    foreach ($key in $EnvBlock.Keys) {
        if ($Existing.env.PSObject.Properties[$key]) {
            $Existing.env.$key = $EnvBlock[$key]
        } else {
            $Existing.env | Add-Member -NotePropertyName $key -NotePropertyValue $EnvBlock[$key]
        }
    }
    $Existing | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsFile -Encoding UTF8
} else {
    [PSCustomObject]@{ env = $EnvBlock } | ConvertTo-Json -Depth 10 |
        Set-Content -Path $SettingsFile -Encoding UTF8
}

Write-Ok "Claude Code configured -> Rakuten AI gateway"

# ── step 4: install rr-standards plugin ───────────────────────────────────────

Write-Run "Installing rr-standards plugin..."

$PluginDest  = "$env:ProgramFiles\Claude\org-plugins"
$RrZipTmp    = Join-Path $env:TEMP "rr-standards.zip"
$RrExtractTmp= Join-Path $env:TEMP "rr-standards-extract"

$RrZipAsset = Join-Path $PSScriptRoot "assets\rr-standards.zip"
$Installed  = $false

try {
    if (Test-Path $RrZipAsset) {
        Copy-Item $RrZipAsset $RrZipTmp -Force
    } else {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/rakathon/workshop/main/setup/assets/rr-standards.zip" `
            -OutFile $RrZipTmp -UseBasicParsing
    }

    if (!(Test-Path $PluginDest)) {
        New-Item -ItemType Directory -Path $PluginDest -Force | Out-Null
    }

    if (Test-Path $RrExtractTmp) { Remove-Item -Recurse -Force $RrExtractTmp }
    Expand-Archive -Path $RrZipTmp -DestinationPath $RrExtractTmp -Force

    $ForgeSkillSrc = Join-Path $RrExtractTmp "rr-standards-main\plugins\forge-skill-creator"
    $ForgeSrc      = Join-Path $RrExtractTmp "rr-standards-main\plugins\forge"

    foreach ($src in @($ForgeSkillSrc, $ForgeSrc)) {
        if (Test-Path $src) {
            $dest = Join-Path $PluginDest (Split-Path $src -Leaf)
            if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
            Copy-Item -Recurse $src $dest
        }
    }

    $Installed = $true
} catch {
    Write-Warn "Could not install rr-standards plugin: $_"
} finally {
    Remove-Item $RrZipTmp -ErrorAction SilentlyContinue
    if (Test-Path $RrExtractTmp) { Remove-Item -Recurse -Force $RrExtractTmp -ErrorAction SilentlyContinue }
}

if ($Installed) { Write-Ok "rr-standards plugin installed" }

# ── done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Ok "Setup complete"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor DarkGray
Write-Host "  1. Open a new terminal window (to reload PATH)" -ForegroundColor DarkGray
Write-Host "  2. cd into your project folder and run: claude" -ForegroundColor DarkGray
Write-Host ""
