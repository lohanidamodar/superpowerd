#!/bin/bash
set -euo pipefail

# Bootstrap superpowerd on a fresh macOS or Linux machine.
#
# Installs: git, gh, Claude Code, tmux (plus Homebrew/WezTerm/skhd on macOS)
# Configures: WezTerm grid, pane titles, account rotation, dashboard
#
# For a rotation-only install with no package manager, dashboard, or window
# manager, use setup-minimal.sh instead.
#
# Usage:
#   bash setup.sh

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"
WORKSPACE="${SUPERPOWERD_WORKSPACE:-$HOME/Local}"

IS_DARWIN=false
[[ "$(uname)" == "Darwin" ]] && IS_DARWIN=true

echo ""
echo "  superpowerd setup ($(uname))"
echo ""

# sed -i takes a mandatory backup suffix on BSD/macOS and an optional one on
# GNU. Passing '' to GNU sed makes it read '' as a filename and fail the script.
sed_inplace() {
  if $IS_DARWIN; then sed -i '' "$@"; else sed -i "$@"; fi
}

if $IS_DARWIN; then
  echo "==> Homebrew"
  if ! command -v brew &>/dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  echo "==> Packages"
  brew install --quiet git gh node tmux mosh 2>/dev/null || true
  brew install --cask --quiet wezterm 2>/dev/null || true
  brew install --cask --quiet font-fira-code-nerd-font 2>/dev/null || true
  brew install --quiet koekeishiya/formulae/skhd 2>/dev/null || true
else
  # No Homebrew on Linux: install only what's actually missing, via whichever
  # package manager exists. WezTerm and the Nerd Font are left to the user —
  # they're desktop apps and rotation drives tmux perfectly well without them.
  echo "==> Packages"
  SUDO=""
  [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null && SUDO="sudo"

  missing=()
  for tool in git gh node tmux; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "    All present: git gh node tmux"
  else
    echo "    Missing: ${missing[*]}"
    # Package names differ from command names on some distros.
    pkgs=()
    for tool in "${missing[@]}"; do
      case "$tool" in
        node) pkgs+=("nodejs") ;;
        *)    pkgs+=("$tool") ;;
      esac
    done

    if command -v apt-get &>/dev/null; then
      $SUDO apt-get update -qq 2>/dev/null || true
      $SUDO apt-get install -y "${pkgs[@]}" 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
      $SUDO dnf install -y "${pkgs[@]}" 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
      $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" 2>/dev/null || true
    elif command -v zypper &>/dev/null; then
      $SUDO zypper install -y "${pkgs[@]}" 2>/dev/null || true
    elif command -v apk &>/dev/null; then
      $SUDO apk add "${pkgs[@]}" 2>/dev/null || true
    else
      echo "    No supported package manager found — install manually: ${pkgs[*]}"
    fi

    # gh in particular is absent from many default repos; don't fail silently.
    for tool in "${missing[@]}"; do
      command -v "$tool" &>/dev/null || echo "    WARNING: $tool still missing — install it manually"
    done
  fi
fi

echo "==> Claude Code"
if ! command -v claude &>/dev/null; then
  npm install -g @anthropic-ai/claude-code
fi

echo "==> GitHub auth"
if ! gh auth status &>/dev/null 2>&1; then
  echo "    Run: gh auth login"
  echo "    Then re-run this script."
  exit 1
fi

# Config files
echo "==> Config files"
if [[ ! -f "$PROJECT_DIR/repos.conf" ]]; then
  cp "$PROJECT_DIR/repos.conf.example" "$PROJECT_DIR/repos.conf"
  echo "    Created repos.conf (edit to customize)"
fi
if [[ ! -f "$PROJECT_DIR/accounts.conf" ]]; then
  cp "$PROJECT_DIR/accounts.conf.example" "$PROJECT_DIR/accounts.conf"
  echo "    Created accounts.conf (edit with your accounts)"
fi
if [[ ! -f "$PROJECT_DIR/shortcuts.conf" ]]; then
  cp "$PROJECT_DIR/shortcuts.conf.example" "$PROJECT_DIR/shortcuts.conf"
  echo "    Created shortcuts.conf (edit to customize)"
fi

# Workspace
echo "==> Workspace: $WORKSPACE"
mkdir -p "$WORKSPACE"

# Clone repos
echo "==> Cloning repos"
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  dir=$(echo "$line" | cut -d= -f1)
  rest=$(echo "$line" | cut -d= -f2)
  remote=$(echo "$rest" | cut -d: -f1)
  if [[ ! -d "$WORKSPACE/$dir" ]]; then
    echo "    $remote -> $dir"
    gh repo clone "$remote" "$WORKSPACE/$dir" 2>/dev/null || echo "    (skipped $dir)"
  fi
done < "$PROJECT_DIR/repos.conf"

# WezTerm
echo "==> WezTerm config"
mkdir -p "$HOME/.config/wezterm"
cp "$PROJECT_DIR/wezterm/wezterm.lua" "$HOME/.config/wezterm/wezterm.lua"

# tmux
echo "==> tmux config"
mkdir -p "$HOME/.config/tmux"
cp "$PROJECT_DIR/wezterm/tmux.conf" "$HOME/.config/tmux/tmux.conf"

# Pane title hook
echo "==> Shell hooks"
mkdir -p "$HOME/.config/iterm2"
cp "$PROJECT_DIR/wezterm/pane-title.zsh" "$HOME/.config/iterm2/pane-title.zsh"

# skhd (macOS-only hotkey daemon; Linux users bind the same actions in their WM)
if $IS_DARWIN; then
  echo "==> skhd"
  mkdir -p "$HOME/.config/skhd"
  skhd --install-service 2>/dev/null || true
  skhd --restart-service 2>/dev/null || true
fi

# .zshrc modifications
echo "==> Shell config"
ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"

if grep -q '# DISABLE_AUTO_TITLE="true"' "$ZSHRC"; then
  sed_inplace 's/# DISABLE_AUTO_TITLE="true"/DISABLE_AUTO_TITLE="true"/' "$ZSHRC"
elif ! grep -q 'DISABLE_AUTO_TITLE="true"' "$ZSHRC"; then
  echo 'DISABLE_AUTO_TITLE="true"' >> "$ZSHRC"
fi

if ! grep -q "SUPERPOWERD_HOME" "$ZSHRC"; then
  cat >> "$ZSHRC" << BLOCK

# superpowerd
export SUPERPOWERD_HOME="$PROJECT_DIR"
export SUPERPOWERD_WORKSPACE="$WORKSPACE"
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
[[ -f ~/.config/iterm2/pane-title.zsh ]] && source ~/.config/iterm2/pane-title.zsh
alias sp-rotate="$PROJECT_DIR/rotation/rotate"
alias sp-monitor="$PROJECT_DIR/rotation/monitor"
alias sp-update="$PROJECT_DIR/rotation/update"
alias sp-dashboard="npx --yes tsx $PROJECT_DIR/dashboard/server.ts"
alias sp-agent="$PROJECT_DIR/sp-agent"
alias sp-session="$PROJECT_DIR/sp-session"
alias sp-list="$PROJECT_DIR/sp-list"
BLOCK
fi

# Make scripts executable
chmod +x \
  "$PROJECT_DIR/rotation/rotate" \
  "$PROJECT_DIR/rotation/monitor" \
  "$PROJECT_DIR/rotation/browser-auth.js" \
  "$PROJECT_DIR/rotation/tokens.js" \
  "$PROJECT_DIR/rotation/update" \
  "$PROJECT_DIR/rotation/capture-hook" \
  "$PROJECT_DIR/sp-agent" \
  "$PROJECT_DIR/sp-session" \
  "$PROJECT_DIR/sp-list" \
  "$PROJECT_DIR/wezterm/title-loop.sh"

# Initialize data directory
mkdir -p "$PROJECT_DIR/data"
if [[ ! -f "$PROJECT_DIR/data/state.json" ]]; then
  echo '{"current": 0}' > "$PROJECT_DIR/data/state.json"
fi

# Capture current account's tokens
echo "==> Capturing tokens"
node "$PROJECT_DIR/rotation/tokens.js" capture 2>/dev/null && \
  echo "    Saved current account tokens" || \
  echo "    (no session — run: node rotation/tokens.js capture-all after authenticating)"

# Install root deps (Playwright's Chromium is fetched by the postinstall hook)
echo "==> Node deps"
cd "$PROJECT_DIR"
npm install --silent 2>/dev/null || echo "    (npm install failed, run: npm install)"

# Install dashboard deps
echo "==> Dashboard"
cd "$PROJECT_DIR/dashboard"
npm install --silent 2>/dev/null
npm run build 2>/dev/null || echo "    (build skipped, run npm run build later)"

# Index historical sessions
echo "==> Session index"
cd "$PROJECT_DIR"
node rotation/index-sessions.js 2>/dev/null || echo "    (indexing skipped)"

# Install custom slash commands
echo "==> Claude commands"
COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$COMMANDS_DIR"
for cmd in "$PROJECT_DIR"/commands/*.md; do
  [[ -f "$cmd" ]] && ln -sf "$cmd" "$COMMANDS_DIR/$(basename "$cmd")"
done

# Install SessionStart hook for auto token capture
echo "==> Auto-capture hook"
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
  node -e "
    var fs = require('fs');
    var settings = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf8'));
    if (!settings.hooks) settings.hooks = {};
    if (!settings.hooks.SessionStart) settings.hooks.SessionStart = [];
    var hookCmd = '$PROJECT_DIR/rotation/capture-hook';
    var exists = settings.hooks.SessionStart.some(function(h) {
      return h.hooks && h.hooks.some(function(hh) { return hh.command && hh.command.includes('capture-hook'); });
    });
    if (!exists) {
      settings.hooks.SessionStart.push({
        matcher: '',
        hooks: [{ type: 'command', command: hookCmd }]
      });
      fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(settings, null, 2) + '\n');
      console.log('    Installed SessionStart hook');
    } else {
      console.log('    Hook already installed');
    }
  "
fi

# Install persistent monitor
echo "==> Monitor service"
NODE_PATH=$(which node)
if $IS_DARWIN; then
  PLIST="$HOME/Library/LaunchAgents/com.superpowerd.monitor.plist"
  cat > "$PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.superpowerd.monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROJECT_DIR/rotation/monitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$PROJECT_DIR/data/monitor.log</string>
    <key>StandardErrorPath</key>
    <string>$PROJECT_DIR/data/monitor.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$(dirname "$NODE_PATH")</string>
    </dict>
</dict>
</plist>
PLIST
  launchctl bootout gui/$(id -u) "$PLIST" 2>/dev/null || true
  launchctl bootstrap gui/$(id -u) "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
  echo "    Installed launchd service (com.superpowerd.monitor)"
else
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/superpowerd-monitor.service" << UNIT
[Unit]
Description=superpowerd rate limit monitor

[Service]
ExecStart=/bin/bash $PROJECT_DIR/rotation/monitor
Restart=always
RestartSec=10
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$(dirname "$NODE_PATH")

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now superpowerd-monitor 2>/dev/null || true
  echo "    Installed systemd user service (superpowerd-monitor)"
fi

# Dashboard service
NPX_PATH=$(which npx)
echo "==> Dashboard service"
if $IS_DARWIN; then
  DASH_PLIST="$HOME/Library/LaunchAgents/com.superpowerd.dashboard.plist"
  cat > "$DASH_PLIST" << DASHPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.superpowerd.dashboard</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NPX_PATH</string>
        <string>tsx</string>
        <string>$PROJECT_DIR/dashboard/server.ts</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR/dashboard</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$PROJECT_DIR/data/dashboard.log</string>
    <key>StandardErrorPath</key>
    <string>$PROJECT_DIR/data/dashboard.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$(dirname "$NODE_PATH")</string>
    </dict>
</dict>
</plist>
DASHPLIST
  launchctl bootout gui/$(id -u) "$DASH_PLIST" 2>/dev/null || true
  launchctl bootstrap gui/$(id -u) "$DASH_PLIST" 2>/dev/null || launchctl load "$DASH_PLIST" 2>/dev/null || true
  echo "    Installed launchd service (com.superpowerd.dashboard)"
else
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/superpowerd-dashboard.service" << DASHUNIT
[Unit]
Description=superpowerd dashboard
After=network.target

[Service]
ExecStart=$NPX_PATH tsx $PROJECT_DIR/dashboard/server.ts
WorkingDirectory=$PROJECT_DIR/dashboard
Restart=always
RestartSec=5
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$(dirname "$NODE_PATH")

[Install]
WantedBy=default.target
DASHUNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now superpowerd-dashboard 2>/dev/null || true
  echo "    Installed systemd user service (superpowerd-dashboard)"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Running services:"
echo "  Monitor:    watching ~/.claude/projects/*.jsonl for rate limits"
echo "  Dashboard:  http://localhost:3848"
echo ""
echo "Commands:"
echo "  sp-rotate             Rotate to next account"
echo "  sp-rotate --status    Show current account"
echo "  sp-monitor --status   Check monitor"
echo "  sp-session <name>     Attach to a tmux session"
echo "  sp-list               List all tmux sessions"
echo ""
if $IS_DARWIN; then
  echo "Shortcuts (in WezTerm, via skhd):"
  echo "  Opt+Cmd+\`   Toggle WezTerm"
  echo "  Opt+Cmd+P   Open PR in browser"
  echo "  Opt+Cmd+N   Create PR"
  echo "  Opt+Cmd+R   Restart Claude"
  echo ""
  echo "Remote access:"
  echo "  1. Enable Remote Login: System Settings > General > Sharing > Remote Login"
  echo "  2. Install Tailscale on this Mac and your phone: https://tailscale.com"
  echo "  3. SSH in: ssh $(whoami)@\$(hostname).tail-net-name.ts.net"
  echo "  4. Use sp-list to see sessions, sp-session <name> to attach"
  echo "  5. For mobile: Blink Shell (iOS) or Termux (Android)"
  echo ""
  echo "Next: Open WezTerm (or restart it) to activate the pane grid."
else
  echo "Shortcuts:"
  echo "  skhd is macOS-only. Bind the equivalents in your window manager,"
  echo "  or drive panes directly through tmux."
  echo ""
  echo "Services:"
  echo "  systemctl --user status superpowerd-monitor"
  echo "  systemctl --user status superpowerd-dashboard"
  echo "  User services stop at logout unless lingering is enabled:"
  echo "    sudo loginctl enable-linger $(whoami)"
  echo ""
  echo "Remote access:"
  echo "  1. Install Tailscale: https://tailscale.com/download/linux"
  echo "  2. SSH in: ssh $(whoami)@\$(hostname).tail-net-name.ts.net"
  echo "  3. Use sp-list to see sessions, sp-session <name> to attach"
  echo "  4. For mobile: Blink Shell (iOS) or Termux (Android)"
  echo ""
  echo "Next: restart your shell to pick up the sp-* aliases."
fi
