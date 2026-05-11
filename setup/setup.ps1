# Rakuten Claude Code Setup — Windows
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

$PollSecs = 2
$TimeoutSecs = 300

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

# ── header ─────────────────────────────────────────────────────────────────────

Write-Header

Write-Host "  This script will:"
Write-Step "1" "Sign you in with your Rakuten account"
Write-Step "2" "Install Git, VS Code, Claude Code extension, and plugins"
Write-Step "3" "Configure Claude Code automatically"
Write-Host ""

# ── step 1: sign in ────────────────────────────────────────────────────────────

Write-StepActive "1" "Sign in with your Rakuten account"
Write-Info "Opening browser — log in and complete MFA..."
Write-Host ""

$Verifier  = New-PkceVerifier
$Challenge = Get-PkceChallenge $Verifier
$State     = [System.BitConverter]::ToString(
                 [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
             ) -replace '-', '' | ForEach-Object { $_.ToLower() }

$AuthUrl = "$OktaIssuer/v1/authorize" +
    "?response_type=code" +
    "&client_id=$ClientId" +
    "&redirect_uri=$(ConvertTo-UrlEncoded $RedirectUri)" +
    "&scope=$(ConvertTo-UrlEncoded $Scopes)" +
    "&state=$State" +
    "&code_challenge=$Challenge" +
    "&code_challenge_method=S256"

Start-Process $AuthUrl

# Poll the clipboard-less way: start a minimal HTTP listener on a local port
# isn't viable without admin rights, so we use a polling loop on the default
# browser via a local redirect catcher running as a background job.

# Start a local HTTP server to catch the OAuth callback
$ListenerJob = Start-Job -ScriptBlock {
    param($redirectUri)
    # Extract port from redirect URI or default to 8080 for local; since redirect
    # goes to the remote callback page, we can't catch it locally.
    # Instead, prompt the user to paste the full redirect URL.
    $null  # placeholder — see below
} -ArgumentList $RedirectUri

Stop-Job $ListenerJob -ErrorAction SilentlyContinue
Remove-Job $ListenerJob -ErrorAction SilentlyContinue

# Since the redirect URI is remote (not localhost), ask the user to paste
# the URL from the browser address bar after sign-in redirects to the callback page.
Write-Host ""
Write-Host "      After signing in, the browser will redirect to a page that may" -ForegroundColor DarkGray
Write-Host "      show an error or blank page. Copy the full URL from the address" -ForegroundColor DarkGray
Write-Host "      bar and paste it below." -ForegroundColor DarkGray
Write-Host ""
$CallbackUrl = Read-Host "  Paste the callback URL here"

if ($CallbackUrl -notmatch "code=") {
    Exit-Error "No authorization code found in the URL. Did you complete sign-in?"
}

$Uri        = [System.Uri]$CallbackUrl
$QueryParts = [System.Web.HttpUtility]::ParseQueryString($Uri.Query)

# Fallback parser if HttpUtility isn't available
if ($null -eq $QueryParts -or $QueryParts["code"] -eq $null) {
    $Code     = ($CallbackUrl -split '[?&]' | Where-Object { $_ -match '^code=' }) -replace '^code=', ''
    $GotState = ($CallbackUrl -split '[?&]' | Where-Object { $_ -match '^state=' }) -replace '^state=', ''
} else {
    $Code     = $QueryParts["code"]
    $GotState = $QueryParts["state"]
}

if ([string]::IsNullOrEmpty($Code)) { Exit-Error "Could not extract authorization code from URL." }
if ($GotState -ne $State)           { Exit-Error "State mismatch — possible CSRF. Aborting." }

Write-Info "Exchanging token..."

$TokenBody = "grant_type=authorization_code" +
    "&client_id=$ClientId" +
    "&redirect_uri=$(ConvertTo-UrlEncoded $RedirectUri)" +
    "&code=$Code" +
    "&code_verifier=$Verifier"

try {
    $TokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri "$OktaIssuer/v1/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $TokenBody
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
    Write-Warn "VS Code CLI 'code' not on PATH — skipping extension install. Open VS Code and install 'Claude Code' from the Marketplace."
}

# Claude plugins
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
    Write-Warn "'claude' CLI not found — skipping plugin install. After installing Claude Code, run:`n        claude plugin add anthropics/claude-plugins-official`n        claude plugin install skill-creator@claude-plugins-official --scope user"
}

Write-Host ""
Write-StepDone "2" "Git, VS Code, Claude Code extension, and plugins ready"

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

# ── summary ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║               Setup Complete!                        ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "      1. Open VS Code in your project folder" -ForegroundColor DarkGray
Write-Host "      2. Press Ctrl+Shift+P → `"Claude: Open Chat`" to start coding" -ForegroundColor DarkGray
Write-Host ""
