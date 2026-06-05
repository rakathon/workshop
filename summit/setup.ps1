# Rakuten Claude Code Setup - Windows (Summit)
# Installs Git, Node.js, VS Code, Claude Code CLI via curl/direct download,
# authenticates via Okta PKCE, writes settings.json, installs rr-standards plugins and MCPs.
#
# Run from PowerShell: Set-ExecutionPolicy Bypass -Scope Process -Force; .\setup.ps1

$ErrorActionPreference = 'Continue'

$OktaIssuer  = "https://rakuten.okta.com/oauth2/ausxr4nv1gcTtBswT357"
$ClientId    = "0oa1hk5jgg1Oz3zDm358"
$RedirectUri = "https://developer.ai.public.rakuten-it.com/callback"
$Scopes      = "openid email profile"
$PatUrl      = "https://developer-backend.ai.public.rakuten-it.com/projects/540fe463-79a3-4b91-894c-ec24c1012bd1/claude-code-aws-bedrock/config"

$PollSecs    = 2
$TimeoutSecs = 300
$DebugPort   = 9229
$Step        = 0
$Total       = 11

# ── helpers ────────────────────────────────────────────────────────────────────

function Write-Ok($msg)      { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Run($msg)     { Write-Host "   ->   $msg" -ForegroundColor DarkGray }
function Write-Warn($msg)    { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Section($msg) {
    $script:Step++
    Write-Host ""
    Write-Host "  [$script:Step/$Total] $msg" -ForegroundColor Cyan
}
function Exit-Error($msg) {
    Write-Host ""
    Write-Host "  [ERR] $msg" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# Refresh PATH in current session
function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
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

$Desktop = "$env:USERPROFILE\Desktop"

# ── cert setup ────────────────────────────────────────────────────────────────
$CertsDir = "$env:USERPROFILE\certs"
if (-not (Test-Path $CertsDir)) { New-Item -ItemType Directory -Path $CertsDir -Force | Out-Null }
if (-not (Test-Path "$CertsDir\rak-ca-bundle.pem")) {
    Write-Host "   ->   Rakuten CA cert not found — downloading..." -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri "http://pki.rakuten-it.com/pki/RootCA.zip" -OutFile "$CertsDir\RootCA.zip" -UseBasicParsing
        Expand-Archive -Path "$CertsDir\RootCA.zip" -DestinationPath $CertsDir -Force
        Remove-Item "$CertsDir\RootCA.zip" -ErrorAction SilentlyContinue
        Write-Host "  [OK]  Rakuten CA cert downloaded to ~\certs" -ForegroundColor Green
    } catch {
        Write-Host "  [!!]  Could not download Rakuten CA cert — continuing without it" -ForegroundColor Yellow
    }
}
$env:NODE_EXTRA_CA_CERTS = "$CertsDir\rak-ca-bundle.pem"

function Install-RestaurantBooking {
    $ZipAsset = Join-Path $PSScriptRoot "assets\restaurant-booking.zip"
    if (-not (Test-Path $ZipAsset)) {
        Write-Warn "restaurant-booking.zip not found — skipping"
        return
    }
    Write-Run "Extracting restaurant-booking to Desktop..."
    $Dest = "$Desktop\restaurant-booking"
    $Tmp  = "$env:TEMP\restaurant-booking-extract"
    if (Test-Path $Tmp)  { Remove-Item -Recurse -Force $Tmp }
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    Expand-Archive -Path $ZipAsset -DestinationPath $Tmp -Force
    $Inner = Get-ChildItem $Tmp | Select-Object -First 1
    if ($Inner -and $Inner.Name -ne "restaurant-booking") {
        Rename-Item $Inner.FullName "restaurant-booking"
    }
    Move-Item "$Tmp\restaurant-booking" $Dest
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
    Write-Ok "restaurant-booking ready at Desktop\restaurant-booking"

    $Landscape = "$Desktop\restaurant-booking\.forge\products\restaurant-booking\competitive\initial-landscape.md"
    if (Test-Path $Landscape) {
        Copy-Item $Landscape "$Desktop\initial-landscape.md" -Force
        Write-Ok "initial-landscape.md copied to Desktop"
    } else {
        Write-Warn "initial-landscape.md not found in restaurant-booking"
    }
}

function Make-Playground {
    $PlaygroundPath = "$Desktop\playground"
    New-Item -ItemType Directory -Path $PlaygroundPath -Force | Out-Null
    Write-Ok "playground directory ready at Desktop\playground"
}

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

# ── already installed? ────────────────────────────────────────────────────────

Add-Type -AssemblyName System.Windows.Forms | Out-Null
$DialogResult = [System.Windows.Forms.MessageBox]::Show(
    "Did you install this setup before?",
    "Rakuten Claude Code Setup",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)

if ($DialogResult -eq [System.Windows.Forms.DialogResult]::Yes) {
    Write-Host ""
    Write-Ok "Re-run detected — refreshing project files only"
    Install-RestaurantBooking
    Make-Playground
    $RbPath = "$Desktop\restaurant-booking"
    if ((Test-Path $RbPath) -and (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Run "Running npm install in restaurant-booking..."
        try { & npm install --prefix $RbPath 2>&1 | Write-Host } catch {}
        Write-Ok "npm install done"
        Write-Run "Starting dev server in background..."
        Start-Process -FilePath "npm" -ArgumentList "run", "dev" -WorkingDirectory $RbPath -WindowStyle Hidden
        Start-Sleep -Seconds 3
        try { Start-Process "http://localhost:3000" } catch {}
        Write-Ok "Dev server started at http://localhost:3000"
    }
    Write-Host ""
    Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Ok "Done"
    Write-Host ""
    exit 0
}

# ── step 1: git ────────────────────────────────────────────────────────────────

Write-Section "Git"

if (Get-Command git -ErrorAction SilentlyContinue) {
    $GitVer = & git --version 2>$null
    Write-Ok "Git already installed ($GitVer)"
} else {
    Write-Run "Downloading Git for Windows..."
    try {
        $GitApi     = Invoke-RestMethod "https://api.github.com/repos/git-for-windows/git/releases/latest"
        $GitAsset   = $GitApi.assets | Where-Object { $_.name -like "*64-bit.exe" } | Select-Object -First 1
        $GitInstaller = "$env:TEMP\git-installer.exe"
        Invoke-WebRequest -Uri $GitAsset.browser_download_url -OutFile $GitInstaller -UseBasicParsing
        Write-Run "Installing Git..."
        Start-Process -FilePath $GitInstaller -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP-" -Wait
        Remove-Item $GitInstaller -ErrorAction SilentlyContinue
        Refresh-Path
        Write-Ok "Git installed"
    } catch {
        Write-Warn "Could not install Git automatically: $_"
    }
}

# ── step 2: node.js ────────────────────────────────────────────────────────────

Write-Section "Node.js"

if (Get-Command node -ErrorAction SilentlyContinue) {
    $NodeVer = & node --version 2>$null
    Write-Ok "Node.js already installed ($NodeVer)"
} else {
    Write-Run "Downloading Node.js LTS..."
    try {
        $NodeIndex   = Invoke-RestMethod "https://nodejs.org/dist/index.json"
        $NodeVersion = ($NodeIndex | Where-Object { $_.lts } | Select-Object -First 1).version
        $NodeMsi     = "$env:TEMP\node-lts.msi"
        Invoke-WebRequest -Uri "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-x64.msi" `
            -OutFile $NodeMsi -UseBasicParsing
        Write-Run "Installing Node.js $NodeVersion..."
        Start-Process msiexec -ArgumentList "/i `"$NodeMsi`" /qn /norestart" -Wait
        Remove-Item $NodeMsi -ErrorAction SilentlyContinue
        Refresh-Path
        Write-Ok "Node.js installed"
    } catch {
        Write-Warn "Could not install Node.js automatically: $_"
    }
}

# ── step 3: claude code cli ────────────────────────────────────────────────────

Write-Section "Claude Code CLI"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    $ClaudeVer = & claude --version 2>$null
    Write-Ok "Claude Code CLI already installed ($ClaudeVer)"
} else {
    Write-Run "Installing Claude Code CLI..."
    try {
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
        $LocalBin = "$env:USERPROFILE\.local\bin"
        $UserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        if ($UserPath -notlike "*$LocalBin*") {
            [System.Environment]::SetEnvironmentVariable("Path", "$UserPath;$LocalBin", "User")
        }
        Refresh-Path
        Write-Ok "Claude Code CLI installed"
    } catch {
        Write-Warn "Could not install Claude Code CLI automatically. Visit https://claude.ai/install"
    }
}

# ── step 4: visual studio code ────────────────────────────────────────────────

Write-Section "Visual Studio Code"

$VsCodeExe = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
if ((Get-Command code -ErrorAction SilentlyContinue) -or (Test-Path $VsCodeExe)) {
    Write-Ok "VS Code already installed"
} else {
    Write-Run "Downloading Visual Studio Code..."
    try {
        $VsCodeInstaller = "$env:TEMP\vscode-installer.exe"
        Invoke-WebRequest -Uri "https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-user" `
            -OutFile $VsCodeInstaller -UseBasicParsing
        Write-Run "Installing Visual Studio Code..."
        Start-Process -FilePath $VsCodeInstaller -ArgumentList "/VERYSILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,addtopath" -Wait
        Remove-Item $VsCodeInstaller -ErrorAction SilentlyContinue
        Refresh-Path
        Write-Ok "VS Code installed"
    } catch {
        Write-Warn "Could not install VS Code automatically: $_"
    }
}

# ── step 5: claude code vs code extension ─────────────────────────────────────

Write-Section "Claude Code VS Code extension"

if (Get-Command code -ErrorAction SilentlyContinue) {
    $Extensions = & code --list-extensions 2>$null
    if ($Extensions -match "anthropic.claude-code") {
        Write-Ok "Claude Code extension already installed"
    } else {
        Write-Run "Installing Claude Code extension..."
        try {
            & code --install-extension anthropic.claude-code 2>$null
            Write-Ok "Claude Code extension installed"
        } catch {
            Write-Warn "Could not install extension — install manually from VS Code marketplace"
        }
    }
} else {
    Write-Warn "VS Code CLI not on PATH — skipping extension install"
}

# ── step 6: okta sign-in ───────────────────────────────────────────────────────

Write-Section "Rakuten OKTA sign-in"

Write-Run "Opening browser for Rakuten OKTA sign-in..."

$Verifier   = New-PkceVerifier
$Challenge  = Get-PkceChallenge $Verifier
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

# ── step 7: write settings.json ───────────────────────────────────────────────

Write-Section "Rakuten AI Gateway config"

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

# ── step 8: rr-standards marketplace ─────────────────────────────────────────

Write-Section "rr-standards marketplace"

$RrZipAsset = Join-Path $PSScriptRoot "assets\rr-standards.zip"
$RrDest     = "$Desktop\rr-standards"
$RrTmp      = "$env:TEMP\rr-standards-extract"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Run "Removing any existing rr-standards marketplace entry..."
    try { & claude plugin marketplace remove rr-standards 2>&1 } catch {}

    if (Test-Path $RrZipAsset) {
        Write-Run "Extracting rr-standards from bundled zip..."
        try {
            if (Test-Path $RrTmp) { Remove-Item -Recurse -Force $RrTmp }
            Expand-Archive -Path $RrZipAsset -DestinationPath $RrTmp -Force
            if (Test-Path $RrDest) { Remove-Item -Recurse -Force $RrDest }
            $RrTop = Get-ChildItem $RrTmp | Where-Object { $_.Name -ne '__MACOSX' } | Select-Object -First 1
            Copy-Item -Recurse $RrTop.FullName $RrDest
            Remove-Item -Recurse -Force $RrTmp -ErrorAction SilentlyContinue
            Write-Ok "rr-standards extracted to Desktop\rr-standards"

            Write-Run "Adding rr-standards marketplace from Desktop\rr-standards..."
            $Out = & claude plugin marketplace add $RrDest 2>&1
            Write-Host $Out
            Write-Ok "rr-standards marketplace added"
        } catch {
            Write-Warn "Could not add rr-standards marketplace: $_"
        }
    } else {
        Write-Warn "rr-standards.zip not found — cannot add marketplace"
    }
} else {
    Write-Warn "claude CLI not on PATH — skipping marketplace step"
}

# ── step 9: install forge plugins ─────────────────────────────────────────────

Write-Section "Installing forge plugins"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    foreach ($plugin in @("forge", "forge-product-management", "forge-skill-creator")) {
        Write-Run "Removing any existing $plugin..."
        try { & claude plugin remove $plugin 2>&1 } catch {}

        Write-Run "Installing $plugin..."
        $Out  = & claude plugin install $plugin 2>&1
        Write-Host $Out
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$plugin installed"
        } else {
            Write-Warn "Could not install $plugin"
        }
    }
} else {
    Write-Warn "claude CLI not on PATH — skipping plugin install"
}

# ── step 10: mcp integrations ─────────────────────────────────────────────────

Write-Section "MCP integrations"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Run "Adding Monday.com MCP..."
    try { & claude mcp add --transport sse mondaycom https://mcp.monday.com/sse --scope user 2>&1; Write-Ok "Monday.com MCP added" } catch { Write-Warn "Monday.com MCP may already be configured" }

    Write-Run "Adding Playwright MCP..."
    try { & claude mcp add playwright -- npx @executeautomation/playwright-mcp-server 2>&1; Write-Ok "Playwright MCP added" } catch { Write-Warn "Playwright MCP may already be configured" }

    Write-Run "Adding BrowserStack MCP..."
    try { & claude mcp add --transport http browserstack-remote https://mcp.browserstack.com/mcp 2>&1; Write-Ok "BrowserStack MCP added" } catch { Write-Warn "BrowserStack MCP may already be configured" }

    Write-Run "Adding Figma MCP..."
    try { & claude mcp add --transport http --scope user figma https://mcp.figma.com/mcp 2>&1; Write-Ok "Figma MCP added" } catch { Write-Warn "Figma MCP may already be configured" }
} else {
    Write-Warn "claude CLI not on PATH — skipping MCP integrations"
}

# ── step 11: restaurant-booking project ──────────────────────────────────────

Write-Section "restaurant-booking project"
Install-RestaurantBooking
Make-Playground

# npm install + dev server
$RbPath = "$Desktop\restaurant-booking"
if ((Test-Path $RbPath) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Run "Running npm install in restaurant-booking..."
    try { & npm install --prefix $RbPath 2>&1 | Write-Host } catch {}
    Write-Ok "npm install done"

    Write-Run "Starting dev server in background..."
    Start-Process -FilePath "npm" -ArgumentList "run", "dev" -WorkingDirectory $RbPath -WindowStyle Hidden
    Start-Sleep -Seconds 3
    try { Start-Process "http://localhost:3000" } catch {}
    Write-Ok "Dev server started at http://localhost:3000"
}

# ── done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Ok "Setup complete"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor DarkGray
Write-Host "  1. Open a new terminal window (to reload PATH)" -ForegroundColor DarkGray
Write-Host "  2. cd into your project folder and run: claude" -ForegroundColor DarkGray
Write-Host ""
