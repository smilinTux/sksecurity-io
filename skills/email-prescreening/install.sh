#!/bin/bash
# install.sh - SKSecurity Email Prescreening Installation
# Part of sksecurity.io - AI-native security tools

set -euo pipefail

SKILL_NAME="email-prescreening"
INSTALL_DIR="$HOME/.openclaw/skills/$SKILL_NAME"
SECURITY_DIR="$HOME/.openclaw/security"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INSTALL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

echo "🛡️ SKSecurity Email Prescreening Installation"
echo "=============================================="

# Check prerequisites
log "Checking prerequisites..."

# Check jq
if ! command -v jq >/dev/null 2>&1; then
    error "jq is required but not installed. Install with: sudo apt install jq"
fi
success "✅ jq found"

# Check curl
if ! command -v curl >/dev/null 2>&1; then
    error "curl is required but not installed. Install with: sudo apt install curl"
fi
success "✅ curl found"

# Check Himalaya
if ! command -v himalaya >/dev/null 2>&1; then
    warn "❌ Himalaya CLI not found"
    echo ""
    echo "To install Himalaya:"
    echo "  cargo install himalaya"
    echo "  # OR download from: https://github.com/soywod/himalaya"
    echo ""
    read -p "Continue installation anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    success "✅ Himalaya CLI found"
fi

# Check Ollama connectivity
log "Testing Ollama connectivity..."
OLLAMA_HOST="${OLLAMA_HOST:-http://192.168.0.100:11434}"

if curl -s "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
    success "✅ Ollama reachable at $OLLAMA_HOST"
    
    # Check for security model
    if curl -s "$OLLAMA_HOST/api/tags" | jq -r '.models[].name' | grep -q "qwen2.5:7b"; then
        success "✅ Security model qwen2.5:7b available"
    else
        warn "⚠️  Security model qwen2.5:7b not found"
        echo "  To install: ollama pull qwen2.5:7b"
    fi
else
    warn "❌ Ollama not reachable at $OLLAMA_HOST"
    echo "  Set OLLAMA_HOST environment variable if using different endpoint"
fi

# Check OpenClaw
if command -v openclaw >/dev/null 2>&1; then
    success "✅ OpenClaw CLI found"
else
    warn "❌ OpenClaw CLI not found - alerts will use file logging fallback"
fi

# Create directories
log "Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$SECURITY_DIR"/{logs,quarantine,patterns}
success "✅ Directories created"

# Install scripts
log "Installing scripts..."
cp email-security-scan.sh "$INSTALL_DIR/"
cp secure-email-processor.sh "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*.sh
success "✅ Scripts installed to $INSTALL_DIR"

# Create configuration file
log "Creating configuration..."
cat > "$SECURITY_DIR/email-prescreening.conf" << EOF
# SKSecurity Email Prescreening Configuration
# Edit this file to customize settings

# Ollama settings
OLLAMA_HOST="http://192.168.0.100:11434"
SECURITY_MODEL="qwen2.5:7b"

# Risk sensitivity (low/medium/high)
RISK_SENSITIVITY="medium"

# Email account to monitor (himalaya account name)
EMAIL_ACCOUNT="default"

# Alert settings
ALERT_METHOD="telegram"
ALERT_TARGET="@chefboyrdave21"

# Quarantine settings  
AUTO_QUARANTINE_HIGH_RISK="true"
QUARANTINE_FOLDER="Quarantine"

# Processing settings
ANALYSIS_TIMEOUT="30"
MAX_CONTENT_LENGTH="10000"

# Logging
LOG_LEVEL="info"
RETAIN_LOGS_DAYS="30"
EOF

success "✅ Configuration created at $SECURITY_DIR/email-prescreening.conf"

# Create threat patterns database
log "Setting up threat patterns..."
cat > "$SECURITY_DIR/patterns/injection-patterns.json" << 'EOF'
{
  "high_risk_patterns": [
    "ignore previous instructions",
    "forget everything before",
    "you are now",
    "pretend you are",
    "act as if",
    "bypass security",
    "override safety",
    "disable safeguards",
    "reveal system prompt",
    "show configuration",
    "admin override",
    "emergency access"
  ],
  "medium_risk_patterns": [
    "urgent action required",
    "immediate response needed", 
    "system administrator",
    "update configuration",
    "change settings",
    "security update",
    "critical patch",
    "temporary access"
  ],
  "trusted_indicators": [
    "partnership inquiry",
    "consultation request",
    "project discussion",
    "meeting request",
    "collaboration opportunity"
  ]
}
EOF

success "✅ Threat patterns database created"

# Setup cron job (optional)
log "Setting up automatic scanning..."
read -p "Enable automatic email scanning every 10 minutes? (Y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Nn]$ ]]; then
    log "Skipping automatic scanning setup"
else
    # Add cron job for automatic scanning
    (crontab -l 2>/dev/null || true; echo "*/10 * * * * $INSTALL_DIR/secure-email-processor.sh --scan-unread >/dev/null 2>&1") | crontab -
    success "✅ Automatic scanning enabled (every 10 minutes)"
fi

# Create symlinks for easy access
log "Creating command aliases..."
mkdir -p "$HOME/.local/bin"
ln -sf "$INSTALL_DIR/email-security-scan.sh" "$HOME/.local/bin/email-security"
ln -sf "$INSTALL_DIR/secure-email-processor.sh" "$HOME/.local/bin/email-processor"

# Add to PATH if not already there
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    warn "Added ~/.local/bin to PATH in ~/.bashrc - restart shell or run: source ~/.bashrc"
fi

success "✅ Command aliases created: email-security, email-processor"

# Installation complete
echo ""
echo "🎉 SKSecurity Email Prescreening Installation Complete!"
echo ""
echo "📋 Next Steps:"
echo "1. Configure email account: himalaya account configure"
echo "2. Test the system: email-security status"
echo "3. Scan existing emails: email-security scan-unread"
echo "4. Edit config if needed: ~/.openclaw/security/email-prescreening.conf"
echo ""
echo "📚 Documentation:"
echo "- Skill guide: $(pwd)/SKILL.md"
echo "- Configuration: $SECURITY_DIR/email-prescreening.conf"
echo "- Logs: $SECURITY_DIR/logs/"
echo ""
echo "🚀 Your AI agent is now protected from email-based prompt injection attacks!"
echo "   Zero maintenance required - the AI handles threat detection automatically."
echo ""
echo "💬 Support: luminaSK@smilintux.org"
echo "🌐 Website: https://sksecurity.io"
echo ""
success "Stay curious AND keep smilin' - even with the security locked down! ✨🛡️"