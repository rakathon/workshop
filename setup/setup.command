#!/usr/bin/env bash
set -euo pipefail

# Rakuten Claude Code Setup — macOS
# Authenticates via Okta PKCE, installs Git/VS Code/Claude Code extension,
# and writes ~/.claude/settings.json.

OKTA_ISSUER="https://rakuten.okta.com/oauth2/ausxr4nv1gcTtBswT357"
CLIENT_ID="0oa1hk5jgg1Oz3zDm358"
REDIRECT_URI="https://developer.ai.public.rakuten-it.com/callback"
SCOPES="openid email profile"
PAT_URL="https://developer-backend.ai.public.rakuten-it.com/projects/540fe463-79a3-4b91-894c-ec24c1012bd1/claude-code-aws-bedrock/config"

POLL=2
TIMEOUT=300

# ── colours & UI helpers ───────────────────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

clear_lines() {
  local n="${1:-1}"
  for (( i=0; i<n; i++ )); do
    printf '\033[1A\033[2K'
  done
}

print_header() {
  clear
  printf "${BOLD}${WHITE}"
  printf '╔══════════════════════════════════════════════════════╗\n'
  printf '║         Rakuten Claude Code Setup (macOS)            ║\n'
  printf '╚══════════════════════════════════════════════════════╝\n'
  printf "${RESET}\n"
}

step()        { printf "  ${BOLD}${CYAN}[${1}]${RESET} ${WHITE}${2}${RESET}\n"; }
step_done()   { printf "  ${BOLD}${GREEN}[${1}]${RESET} ${GREEN}${2}${RESET}\n"; }
step_active() { printf "  ${BOLD}${YELLOW}[${1}]${RESET} ${YELLOW}${2}${RESET}\n"; }
info()        { printf "      ${DIM}${1}${RESET}\n"; }
success()     { printf "\n  ${BOLD}${GREEN}✓  ${1}${RESET}\n"; }
warn()        { printf "\n  ${YELLOW}⚠  ${1}${RESET}\n" >&2; }
die()         { printf "\n  ${BOLD}${RED}✗  Error: ${1}${RESET}\n\n" >&2; exit 1; }

[[ "$OSTYPE" == darwin* ]] || die "This script requires macOS."
command -v openssl   &>/dev/null || die "openssl not found."
command -v curl      &>/dev/null || die "curl not found."
command -v osascript &>/dev/null || die "osascript not found."

# ── header ─────────────────────────────────────────────────────────────────────

print_header

printf "  This script will:\n"
step "1" "Sign you in with your Rakuten account"
step "2" "Install Git, VS Code, Claude Code extension, Claude Desktop, and plugins"
step "3" "Configure Claude Code automatically"
step "4" "Install Claude Desktop configuration profile"
step "5" "Install plugins for Claude Desktop"
step "6" "Set up Snowflake MCP (optional)"
printf "\n"

# ── step 1: sign in ────────────────────────────────────────────────────────────

step_active "1" "Sign in with your Rakuten account"
info "Opening Safari — log in and complete MFA..."
printf "\n"

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

VERIFIER=$(openssl rand -base64 48 | tr -d '=+/\n' | tr '+/' '-_' | cut -c1-64)
CHALLENGE=$(printf '%s' "$VERIFIER" \
  | openssl dgst -binary -sha256 \
  | openssl base64 \
  | tr -d '=\n' \
  | tr '+/' '-_')
STATE=$(openssl rand -hex 16)

AUTH_URL="${OKTA_ISSUER}/v1/authorize\
?response_type=code\
&client_id=${CLIENT_ID}\
&redirect_uri=$(urlencode "$REDIRECT_URI")\
&scope=$(urlencode "$SCOPES")\
&state=${STATE}\
&code_challenge=${CHALLENGE}\
&code_challenge_method=S256"

open -a Safari
for i in $(seq 1 30); do
  osascript -e 'tell application "Safari" to get version' &>/dev/null && break
  sleep 1
done

osascript <<APPLES
tell application "Safari"
  activate
  if (count of windows) = 0 then
    make new document with properties {URL:"${AUTH_URL}"}
  else
    set URL of current tab of front window to "${AUTH_URL}"
  end if
end tell
APPLES

elapsed=0
CODE=""
while (( elapsed < TIMEOUT )); do
  TAB_URL=$(osascript 2>/dev/null <<'APPLES' || true
tell application "Safari"
  if (count of windows) > 0 then
    return URL of current tab of front window
  end if
  return ""
end tell
APPLES
  )

  if [[ "$TAB_URL" == *"developer.ai.public.rakuten-it.com/callback"* ]] \
  && [[ "$TAB_URL" == *"code="* ]]; then
    CODE=$(printf '%s' "$TAB_URL" | grep -o 'code=[^&]*' | head -1 | cut -d= -f2)
    GOT_STATE=$(printf '%s' "$TAB_URL" | grep -o 'state=[^&]*' | head -1 | cut -d= -f2)
    [[ "$GOT_STATE" == "$STATE" ]] || die "State mismatch — possible CSRF. Aborting."

    osascript 2>/dev/null <<'APPLES' || true
tell application "Safari"
  close front window
end tell
APPLES
    break
  fi

  frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  idx=$(( (elapsed / POLL) % 10 ))
  printf "\r      ${CYAN}${frames[$idx]}${RESET}  ${DIM}Waiting for sign-in... (${elapsed}s)${RESET}   "

  sleep "$POLL"
  elapsed=$(( elapsed + POLL ))
done
printf "\r\033[2K"

[[ -n "$CODE" ]] || die "Timed out after ${TIMEOUT}s. Did you complete the sign-in?"

info "Exchanging token..."

TOKEN_RESPONSE=$(curl -fsS \
  -X POST "${OKTA_ISSUER}/v1/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}" \
  --data-urlencode "code=${CODE}" \
  --data-urlencode "code_verifier=${VERIFIER}" \
) || die "Token exchange failed."

ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" \
  | grep -o '"access_token":"[^"]*"' \
  | sed 's/"access_token":"//;s/"$//')
[[ -n "$ACCESS_TOKEN" ]] || die "No access_token in response."

info "Fetching access key..."

PAT_RESPONSE=$(curl -sS \
  -X POST "$PAT_URL" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json, text/plain, */*" \
  -H "Origin: https://developer.ai.public.rakuten-it.com" \
  -H "Referer: https://developer.ai.public.rakuten-it.com/" \
  --write-out "\nHTTP_STATUS:%{http_code}" 2>&1)

HTTP_CODE=$(printf '%s' "$PAT_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
PAT_BODY=$(printf '%s' "$PAT_RESPONSE" | sed '/HTTP_STATUS:/d')
[[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]] \
  || die "PAT request failed (HTTP $HTTP_CODE): $PAT_BODY"

PAT=$(printf '%s' "$PAT_BODY" \
  | grep -o '"secret_key":"[^"]*"' \
  | sed 's/"secret_key":"//;s/"$//')
[[ -n "$PAT" ]] || die "No secret_key in response."

# Fetch user email from Okta userinfo
USER_EMAIL=$(curl -sS "${OKTA_ISSUER}/v1/userinfo" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  | grep -o '"email":"[^"]*"' \
  | sed 's/"email":"//;s/"$//')
[[ -n "$USER_EMAIL" ]] && export COWORK_USER_EMAIL="$USER_EMAIL"

clear_lines 4
step_done "1" "Signed in successfully"
[[ -n "$USER_EMAIL" ]] && info "Signed in as: ${USER_EMAIL}"

# ── step 2: install Git, VS Code, Claude Code extension ───────────────────────

step_active "2" "Install Git, VS Code, Claude Code extension, Claude Desktop, and plugins"
printf "\n"

# Git — already present on macOS via Xcode CLT; install CLT if absent
if ! command -v git &>/dev/null; then
  info "Installing Xcode Command Line Tools (includes Git)..."
  xcode-select --install 2>/dev/null || true
  # Wait for git to become available (CLT install is async/interactive)
  for i in $(seq 1 60); do
    command -v git &>/dev/null && break
    sleep 5
  done
  command -v git &>/dev/null || die "Git not found after CLT install. Please install manually and re-run."
  info "Git installed."
else
  info "Git already installed ($(git --version))."
fi

# VS Code — install via direct download if not present
if ! command -v code &>/dev/null && [[ ! -d "/Applications/Visual Studio Code.app" ]]; then
  info "Downloading VS Code..."
  VSCODE_ZIP=/tmp/vscode-setup.zip
  rm -f "$VSCODE_ZIP"
  curl -fsSL --progress-bar \
    "https://update.code.visualstudio.com/latest/darwin-universal/stable" \
    -o "$VSCODE_ZIP" \
    || die "Failed to download VS Code."
  printf "\n"

  info "Installing VS Code..."
  unzip -q "$VSCODE_ZIP" -d /Applications/ \
    || die "Failed to install VS Code."
  rm -f "$VSCODE_ZIP"
  info "VS Code installed."
else
  info "VS Code already installed."
fi

# Ensure the `code` CLI is on PATH
CODE_CLI="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
if ! command -v code &>/dev/null && [[ -f "$CODE_CLI" ]]; then
  export PATH="$PATH:$(dirname "$CODE_CLI")"
fi

# Claude Code CLI
if ! command -v claude &>/dev/null; then
  info "Installing Claude Code CLI..."
  curl -fsSL https://claude.ai/install.sh | bash \
    || warn "Could not install Claude Code CLI automatically. Visit https://claude.ai/install for instructions."
  # Refresh PATH in case installer added to a new location
  export PATH="$HOME/.local/bin:$PATH"
else
  info "Claude Code CLI already installed ($(claude --version 2>/dev/null || true))."
fi

# Node.js + npx via nvm
if ! command -v npx &>/dev/null; then
  info "Installing Node.js (includes npx)..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    || warn "Could not install nvm. Visit https://nodejs.org for instructions."
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
  nvm install --lts 2>/dev/null \
    || warn "Could not install Node.js via nvm."
  export PATH="$NVM_DIR/versions/node/$(nvm current 2>/dev/null)/bin:$PATH"
else
  info "Node.js already installed ($(node --version 2>/dev/null || true))."
fi

# Claude Code VS Code extension
if command -v code &>/dev/null; then
  if ! code --list-extensions 2>/dev/null | grep -qi "anthropic.claude-code"; then
    info "Installing Claude Code extension..."
    code --install-extension anthropic.claude-code --force \
      || warn "Could not install Claude Code extension automatically. Install it manually from the VS Code Marketplace."
  else
    info "Claude Code extension already installed."
  fi
else
  warn "VS Code CLI 'code' not on PATH — skipping extension install. Open VS Code and install 'Claude Code' from the Marketplace."
fi

# Claude Desktop
if [[ ! -d "/Applications/Claude.app" ]]; then
  info "Downloading Claude Desktop (317 MB)..."
  CLAUDE_DMG=/tmp/Claude-setup.dmg
  rm -f "$CLAUDE_DMG"
  curl -fsSL \
    "https://downloads.claude.ai/releases/darwin/universal/1.5354.0/Claude-9a9e3d5a4a368f0f49a80dc303b0ed1a18bfedad.dmg" \
    -o "$CLAUDE_DMG" &
  CURL_PID=$!
  frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  i=0
  while kill -0 "$CURL_PID" 2>/dev/null; do
    printf "\r      ${CYAN}${frames[$((i % 10))]}${RESET}  ${DIM}Downloading...${RESET}   "
    sleep 0.2
    i=$(( i + 1 ))
  done
  printf "\r\033[2K"
  if ! wait "$CURL_PID"; then
    warn "Failed to download Claude Desktop — install manually from https://claude.ai/download"
  else
    info "Installing Claude Desktop..."
    CLAUDE_MOUNT=$(hdiutil attach "$CLAUDE_DMG" -nobrowse -noverify -plist 2>/dev/null \
      | python3 -c "import sys,plistlib,io; d=plistlib.load(io.BytesIO(sys.stdin.buffer.read())); print([e['mount-point'] for e in d['system-entities'] if 'mount-point' in e][-1])" 2>/dev/null || true)
    if [[ -d "$CLAUDE_MOUNT/Claude.app" ]]; then
      cp -R "$CLAUDE_MOUNT/Claude.app" /Applications/
      hdiutil detach "$CLAUDE_MOUNT" -quiet 2>/dev/null || true
      info "Claude Desktop installed."
    else
      warn "Could not install Claude Desktop — install manually from https://claude.ai/download"
    fi
    rm -f "$CLAUDE_DMG"
  fi
else
  info "Claude Desktop already installed."
fi

clear_lines 2
step_done "2" "Git, VS Code, Claude Code extension, Claude Desktop, and Node.js ready"

# ── step 3: write ~/.claude/settings.json ─────────────────────────────────────

step_active "3" "Configuring Claude Code"
info "Writing ~/.claude/settings.json..."

SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"

if [[ -f "$SETTINGS_FILE" ]] && command -v python3 &>/dev/null; then
  # Merge: preserve existing keys not in our list, overwrite the ones we own
  UPDATED=$(python3 - "$SETTINGS_FILE" <<PYEOF
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

env = data.setdefault("env", {})
env["ANTHROPIC_BEDROCK_BASE_URL"] = "https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1"
env["AWS_BEARER_TOKEN_BEDROCK"]   = """$PAT"""
env["CLAUDE_CODE_USE_BEDROCK"]    = "1"
env["CLAUDE_CODE_SKIP_BEDROCK_AUTH"] = "1"
env["CLAUDE_CODE_ENABLE_TELEMETRY"]  = "1"
env["OTEL_METRICS_EXPORTER"]         = "otlp"
env["OTEL_LOGS_EXPORTER"]            = "otlp"
env["OTEL_EXPORTER_OTLP_PROTOCOL"]   = "http/protobuf"
env["OTEL_EXPORTER_OTLP_ENDPOINT"]   = "https://api.ai.public.rakuten-it.com/otel"
env["OTEL_EXPORTER_OTLP_HEADERS"]    = "Authorization=$PAT"

print(json.dumps(data, indent=2))
PYEOF
  )
  printf '%s\n' "$UPDATED" > "$SETTINGS_FILE"
else
  # Fresh write
  cat > "$SETTINGS_FILE" <<JSON
{
  "env": {
    "ANTHROPIC_BEDROCK_BASE_URL": "https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1",
    "AWS_BEARER_TOKEN_BEDROCK": "$PAT",
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "1",
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://api.ai.public.rakuten-it.com/otel",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=$PAT"
  }
}
JSON
fi

clear_lines 2
step_done "3" "Claude Code configured"

# ── step 3b: install Claude plugins (needs settings.json to be present) ───────

step_active "3" "Installing Claude plugins"
printf "\n"

if command -v claude &>/dev/null; then
  info "Installing skill-creator plugin..."
  claude plugin install skill-creator@claude-plugins-official --scope user 2>/dev/null \
    || warn "Could not install skill-creator — run manually: claude plugin install skill-creator@claude-plugins-official --scope user"
else
  warn "'claude' CLI not found — skipping plugin install. After installing Claude Code, run:\n        claude plugin add anthropics/claude-plugins-official\n        claude plugin install skill-creator@claude-plugins-official --scope user"
fi

clear_lines 2
step_done "3" "Claude plugins installed"

# ── step 4: install Claude Desktop mobileconfig ───────────────────────────────

MOBILECONFIG_FALLBACK='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
	<dict>
		<key>PayloadContent</key>
		<array>
			<dict>
				<key>PayloadType</key>
				<string>com.anthropic.claudefordesktop</string>
				<key>PayloadIdentifier</key>
				<string>com.anthropic.claudefordesktop.settings</string>
				<key>PayloadUUID</key>
				<string>0CBCAB4D-4E52-4C0C-A13C-FB31188A443A</string>
				<key>PayloadVersion</key>
				<integer>1</integer>
				<key>PayloadDisplayName</key>
				<string>Claude Desktop</string>
				<key>coworkEgressAllowedHosts</key>
				<string>["*"]</string>
				<key>inferenceProvider</key>
				<string>bedrock</string>
				<key>inferenceBedrockRegion</key>
				<string>us-east-1</string>
				<key>inferenceBedrockBearerToken</key>
				<string>{{BEARER_TOKEN}}</string>
				<key>inferenceBedrockBaseUrl</key>
				<string>https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1</string>
				<key>inferenceModels</key>
				<string>[{"name":"us.anthropic.claude-sonnet-4-6","supports1m":true}]</string>
				<key>managedMcpServers</key>
				<string>[{"name":"slack-v1","toolPolicy":{"slack_search_public":"allow","slack_search_public_and_private":"allow","slack_search_channels":"allow","slack_search_users":"allow","slack_read_channel":"allow","slack_read_thread":"allow","slack_read_canvas":"allow","slack_read_user_profile":"allow","slack_list_channel_members":"allow","slack_read_file":"allow","slack_search_emojis":"allow","slack_get_reactions":"allow"},"source":"user","transport":"http","url":"https://mcp.slack.com/mcp","oauth":{"clientId":"1601185624273.8899143856786","callbackPort":3118,"callbackHost":"localhost"}},{"name":"datadog-prod","toolPolicy":{"analyze_datadog_logs":"allow","get_datadog_dashboard":"allow","get_datadog_incident":"allow","get_datadog_metric":"allow","get_datadog_metric_context":"allow","get_datadog_notebook":"allow","get_datadog_trace":"allow","get_widget_reference":"allow","list_datadog_skills":"allow","load_datadog_skill":"allow","search_datadog_dashboards":"allow","search_datadog_events":"allow","search_datadog_hosts":"allow","search_datadog_incidents":"allow","search_datadog_logs":"allow","search_datadog_metrics":"allow","search_datadog_monitors":"allow","search_datadog_notebooks":"allow","search_datadog_rum_events":"allow","search_datadog_service_dependencies":"allow","search_datadog_services":"allow","search_datadog_spans":"allow"},"source":"user","transport":"http","url":"https://mcp.datadoghq.com/api/unstable/mcp-server/mcp","oauth":true},{"name":"atlassian","toolPolicy":{"atlassianUserInfo":"allow","getConfluencePage":"allow","searchConfluenceUsingCql":"allow","getConfluenceSpaces":"allow","getPagesInConfluenceSpace":"allow","getConfluencePageFooterComments":"allow","getConfluencePageInlineComments":"allow","getConfluenceCommentChildren":"allow","getConfluencePageDescendants":"allow","getJiraIssue":"allow","getTransitionsForJiraIssue":"allow","getJiraIssueRemoteIssueLinks":"allow","getVisibleJiraProjects":"allow","getJiraProjectIssueTypesMetadata":"allow","getJiraIssueTypeMetaWithFields":"allow","searchJiraIssuesUsingJql":"allow","lookupJiraAccountId":"allow","getIssueLinkTypes":"allow","search":"allow","fetch":"allow"},"source":"user","transport":"http","url":"https://mcp.atlassian.com/v1/mcp","oauth":true},{"name":"monday-com","toolPolicy":{"get_board_items_page":"allow","get_updates":"allow","get_board_activity":"allow","get_board_info":"allow","get_full_board_data":"allow","list_users_and_teams":"allow","get_form":"allow","get_graphql_schema":"allow","get_column_type_info":"allow","get_type_details":"allow","read_docs":"allow","workspace_info":"allow","list_workspaces":"allow","all_widgets_schema":"allow","board_insights":"allow","search":"allow","get_user_context":"allow","get_assets":"allow","get_notetaker_meetings":"allow","get_agent":"allow","get_monday_dev_sprints_boards":"allow","get_sprints_metadata":"allow","get_sprint_summary":"allow"},"source":"user","transport":"sse","url":"https://mcp.monday.com/sse","oauth":true},{"name":"uber-context","source":"user","transport":"http","url":"https://uber-context-system.shared-np.rr-it.com/mcp"},{"name":"browserStack","source":"user","transport":"http","url":"https://mcp.browserstack.com/mcp","oauth":true},{"name":"datadog-nonprod","toolPolicy":{"analyze_datadog_logs":"allow","get_datadog_dashboard":"allow","get_datadog_incident":"allow","get_datadog_metric":"allow","get_datadog_metric_context":"allow","get_datadog_notebook":"allow","get_datadog_trace":"allow","get_widget_reference":"allow","list_datadog_skills":"allow","load_datadog_skill":"allow","search_datadog_dashboards":"allow","search_datadog_events":"allow","search_datadog_hosts":"allow","search_datadog_incidents":"allow","search_datadog_logs":"allow","search_datadog_metrics":"allow","search_datadog_monitors":"allow","search_datadog_notebooks":"allow","search_datadog_rum_events":"allow","search_datadog_service_dependencies":"allow","search_datadog_services":"allow","search_datadog_spans":"allow"},"source":"user","transport":"http","url":"https://mcp.datadoghq.com/api/unstable/mcp-server/mcp","oauth":true},{"name":"figma","toolPolicy":{"get_design_context":"allow","get_variable_defs":"allow","get_screenshot":"allow","get_code_connect_map":"allow","add_code_connect_map":"allow","get_code_connect_suggestions":"allow","send_code_connect_mappings":"allow","get_metadata":"allow","create_design_system_rules":"allow","get_figjam":"allow"},"source":"user","transport":"sse","url":"http://127.0.0.1:3845/sse"},{"name":"iterable","source":"user","transport":"stdio","command":"{{NPX_PATH}}","args":["@iterable/mcp"],"env":{"ITERABLE_API_KEY":"{{ITERABLE_API_KEY}}","ITERABLE_BASE_URL":"https://api.iterable.com","ITERABLE_ENABLE_WRITES":"true"}},{"name":"annalise-rewards","toolPolicy":{"get_domain":"allow","list_entities":"allow","list_domains":"allow","monitor_analysis":"allow","get_analysis_step_details":"allow","get_entity":"allow","initiate_analysis":"allow","get_field":"allow","search_model":"allow","list_databases":"allow","list_shemas":"allow","list_tables":"allow","get_table_info":"allow","list_workspaces":"allow","list_workspace_branches":"allow","get_session_workspace_and_branch":"allow","get_branch_history":"allow","list_agents":"allow","get_agents":"allow","list_context_items":"allow","get_context_items":"allow"},"source":"user","transport":"http","url":"https://mcp.rakuten.honeydew.cloud/mcp","oauth":true},{"name":"Snowflake","source":"user","transport":"stdio","command":"uvx","args":["snowflake-labs-mcp","--service-config-file","~/snowflake-mcp/tools_config.yaml","--connection-name","default"],"toolPolicy":{"list_objects":"allow","describe_object":"allow","run_snowflake_query":"allow"}}]</string>
				<key>banner</key>
				<string>{"enabled":true,"text":"Rakuten Rewards - CoWork - v1.1.0","backgroundColor":"#7B30C6","textColor":"#FFFFFF","linkUrl":"https://www.rakuten.com"}</string>
			</dict>
		</array>
		<key>PayloadDisplayName</key>
		<string>Claude Desktop Third-Party Inference</string>
		<key>PayloadIdentifier</key>
		<string>com.anthropic.claudefordesktop.profile</string>
		<key>PayloadType</key>
		<string>Configuration</string>
		<key>PayloadUUID</key>
		<string>5294DE36-EBCB-4778-81DC-35849822638C</string>
		<key>PayloadVersion</key>
		<integer>1</integer>
		<key>PayloadScope</key>
		<string>User</string>
	</dict>
</plist>'

step_active "4" "Install Claude Desktop configuration profile"
info "Preparing configuration profile..."

MOBILECONFIG_TMP=/tmp/Claude-setup.mobileconfig
rm -f "$MOBILECONFIG_TMP"
trap 'sleep 3; rm -f "$MOBILECONFIG_TMP"' EXIT

PAT_SED=$(printf '%s' "$PAT" | sed 's/[&/\]/\\&/g')

ITERABLE_API_KEY="e038f648839d40f1a1edcfa7c9be44c0"
ITERABLE_SED=$(printf '%s' "$ITERABLE_API_KEY" | sed 's/[&/\]/\\&/g')

export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
NPX_PATH=$(command -v npx 2>/dev/null || true)
NPX_SED=$(printf '%s' "$NPX_PATH" | sed 's/[&/\]/\\&/g')

printf '%s' "$MOBILECONFIG_FALLBACK" \
  | sed "s|{{BEARER_TOKEN}}|${PAT_SED}|g" \
  | sed "s|{{ITERABLE_API_KEY}}|${ITERABLE_SED}|g" \
  | sed "s|{{NPX_PATH}}|${NPX_SED}|g" \
  > "$MOBILECONFIG_TMP"

open "$MOBILECONFIG_TMP"

step_done "4" "Configuration profile opened — click Install in System Settings"

# ── step 5: install org-plugins ───────────────────────────────────────────────

step_active "5" "Install plugins for Claude Desktop"
info "Copying plugins to /Library/Application Support/Claude/org-plugins/..."

PLUGIN_DEST="/Library/Application Support/Claude/org-plugins"

# Eject old stale mounts, keep only the newest (highest suffix = most recently opened)
ALL_VOLS=()
while IFS= read -r vol; do
  [[ -n "$vol" ]] && ALL_VOLS+=("$vol")
done < <(mount | grep -oi '/Volumes/Rakuten Claude Code Setup[^(]*' | sed 's/ *$//')

if [[ ${#ALL_VOLS[@]} -gt 0 ]]; then
  # Sort by version — last line is the newest
  PLUGIN_VOLUME=""
  while IFS= read -r vol; do
    PLUGIN_VOLUME="$vol"
  done < <(printf '%s\n' "${ALL_VOLS[@]}" | sort -V)
  info "Using volume: ${PLUGIN_VOLUME}"
  for vol in "${ALL_VOLS[@]}"; do
    if [[ "$vol" != "$PLUGIN_VOLUME" ]]; then
      info "Ejecting old volume: ${vol}"
      hdiutil detach "$vol" -quiet 2>/dev/null || true
    fi
  done
else
  PLUGIN_VOLUME=""
  warn "Could not find Rakuten Claude Code Setup volume — skipping plugin install"
fi

if [[ -n "$PLUGIN_VOLUME" ]]; then

# Extract all zips first (no admin needed), then do one single privileged copy
RR_ZIP="${PLUGIN_VOLUME}/rr-standards.zip"
HD_ZIP="${PLUGIN_VOLUME}/honeydew-ai-claude.zip"
ADVISOR_ZIP="${PLUGIN_VOLUME}/rr-advisor.zip"

RR_TMP=/tmp/rr-standards-extract
HD_TMP=/tmp/honeydew-ai-claude-extract
ADVISOR_TMP=/tmp/rr-advisor-extract

INSTALL_CMD="mkdir -p '${PLUGIN_DEST}'"
INSTALL_CMD+=" && rm -rf '${PLUGIN_DEST}/ai-summit' '${PLUGIN_DEST}/rr-standards' '${PLUGIN_DEST}/forge-skill-creator' '${PLUGIN_DEST}/forge' '${PLUGIN_DEST}/honeydew-ai-claude' '${PLUGIN_DEST}/advisor'"

HAS_RR=false; HAS_HD=false; HAS_ADVISOR=false

if [[ -f "$RR_ZIP" ]]; then
  rm -rf "$RR_TMP" && mkdir -p "$RR_TMP"
  unzip -q "$RR_ZIP" -d "$RR_TMP"
  INSTALL_CMD+=" && cp -R '${RR_TMP}/rr-standards-main/plugins/forge-skill-creator' '${PLUGIN_DEST}/'"
  INSTALL_CMD+=" && cp -R '${RR_TMP}/rr-standards-main/plugins/forge' '${PLUGIN_DEST}/'"
  HAS_RR=true
fi

if [[ -f "$HD_ZIP" ]]; then
  rm -rf "$HD_TMP" && mkdir -p "$HD_TMP/honeydew-ai-claude"
  unzip -q "$HD_ZIP" -d "$HD_TMP/honeydew-ai-claude"
  INSTALL_CMD+=" && rsync -a '${HD_TMP}/honeydew-ai-claude' '${PLUGIN_DEST}/'"
  HAS_HD=true
else
  warn "honeydew-ai-claude.zip not found on volume — skipping"
fi

if [[ -f "$ADVISOR_ZIP" ]]; then
  rm -rf "$ADVISOR_TMP" && mkdir -p "$ADVISOR_TMP"
  unzip -q "$ADVISOR_ZIP" -d "$ADVISOR_TMP"
  INSTALL_CMD+=" && rsync -a '${ADVISOR_TMP}/advisor' '${PLUGIN_DEST}/'"
  HAS_ADVISOR=true
else
  warn "rr-advisor.zip not found on volume — skipping"
fi

# Single admin prompt for all plugins
OSASCRIPT_ERR=$(osascript 2>&1 <<OSASCRIPT
do shell script "${INSTALL_CMD}" with administrator privileges
OSASCRIPT
)
INSTALL_STATUS=$?

rm -rf "$RR_TMP" "$HD_TMP" "$ADVISOR_TMP"

if [[ $INSTALL_STATUS -eq 0 ]]; then
  $HAS_RR      && step_done "5" "forge-skill-creator + forge plugins installed"
  $HAS_HD      && step_done "5" "honeydew-ai-claude plugin installed"
  $HAS_ADVISOR && step_done "5" "rr-advisor plugin installed"
else
  warn "Could not install plugins: ${OSASCRIPT_ERR}"
fi

fi # end PLUGIN_VOLUME check

# ── summary ────────────────────────────────────────────────────────────────────

# ── step 6: snowflake mcp setup ───────────────────────────────────────────────

step_active "6" "Set up Snowflake MCP for CoWork"

SNOWFLAKE_ANSWER=$(osascript 2>/dev/null <<'APPLES'
button returned of (display dialog "Do you have Snowflake access?\n\nClick Yes to install Snowflake MCP so CoWork can query Snowflake on your behalf." with title "Snowflake Setup" buttons {"No", "Yes"} default button "Yes" with icon note)
APPLES
)

if [[ "$SNOWFLAKE_ANSWER" == "Yes" ]]; then

  # Check / install uvx
  info "Checking for uvx..."
  UVX_PATH=""
  if command -v uvx &>/dev/null; then
    UVX_PATH=$(command -v uvx)
  elif [[ -f "$HOME/.local/bin/uvx" ]]; then
    UVX_PATH="$HOME/.local/bin/uvx"
  fi

  if [[ -z "$UVX_PATH" ]]; then
    info "uvx not found — installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    if [[ -f "$HOME/.local/bin/uvx" ]]; then
      UVX_PATH="$HOME/.local/bin/uvx"
    else
      warn "uvx still not found after install — Snowflake MCP skipped. Restart Terminal and re-run."
    fi
  fi

  if [[ -n "$UVX_PATH" ]]; then
    info "uvx found: ${UVX_PATH}"

    # Pre-cache snowflake-labs-mcp
    info "Caching snowflake-labs-mcp..."
    "$UVX_PATH" --from snowflake-labs-mcp snowflake-labs-mcp -h &>/dev/null \
      || warn "Could not cache snowflake-labs-mcp — run manually: uvx --from snowflake-labs-mcp snowflake-labs-mcp"

    # Write ~/.snowflake/connections.toml
    info "Writing ~/.snowflake/connections.toml..."
    mkdir -p "$HOME/.snowflake"
    cat > "$HOME/.snowflake/connections.toml" << EOF
[default]
account = "rakutenusa-ebates"
user = "${COWORK_USER_EMAIL}"
authenticator = "externalbrowser"
EOF
    info "Snowflake user set to: ${COWORK_USER_EMAIL}"

    # Write ~/snowflake-mcp/tools_config.yaml
    info "Writing ~/snowflake-mcp/tools_config.yaml..."
    mkdir -p "$HOME/snowflake-mcp"
    cat > "$HOME/snowflake-mcp/tools_config.yaml" << 'YAMLEOF'
agent_services: []
search_services: []
analyst_services: []

other_services:
  object_manager: true
  query_manager: true
  semantic_manager: false

sql_statement_permissions:
  - Select: true
  - Describe: true
  - Use: true
  - Create: false
  - Drop: false
  - Insert: false
  - Update: false
  - Delete: false
  - Unknown: false
YAMLEOF

    step_done "6" "Snowflake MCP configured (restart CoWork to activate)"
  else
    step_done "6" "Snowflake MCP skipped — uvx not found"
  fi

else
  step_done "6" "Snowflake MCP skipped"
fi

printf "\n"
printf "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}\n"
printf "  ${BOLD}${GREEN}║                  Setup Complete! 🎉                  ║${RESET}\n"
printf "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "  ${WHITE}Next steps:${RESET}\n"
printf "  ${DIM}1. Click ${RESET}${BOLD}Install${RESET}${DIM} in the System Settings window that just opened${RESET}\n"
printf "  ${DIM}2. Open VS Code in your project folder${RESET}\n"
printf "  ${DIM}3. Press ${RESET}${BOLD}Cmd+Shift+P${RESET}${DIM} → \"Claude: Open Chat\" to start coding${RESET}\n"
printf "\n"
