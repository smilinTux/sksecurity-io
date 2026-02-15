#!/bin/bash
# secure-email-processor.sh - Main email security processing daemon
# Part of SKSecurity - sksecurity.io

set -euo pipefail

# Configuration
SECURITY_DIR="$HOME/.openclaw/security"
CONFIG_FILE="$SECURITY_DIR/email-prescreening.conf"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Load configuration if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Default values
OLLAMA_HOST="${OLLAMA_HOST:-http://192.168.0.100:11434}"
SECURITY_MODEL="${SECURITY_MODEL:-qwen2.5:7b}"
EMAIL_ACCOUNT="${EMAIL_ACCOUNT:-default}"
QUARANTINE_FOLDER="${QUARANTINE_FOLDER:-Quarantine}"
LOG_LEVEL="${LOG_LEVEL:-info}"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    [[ "$LOG_LEVEL" == "debug" ]] || [[ "$LOG_LEVEL" == "info" ]] && echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

debug() {
    [[ "$LOG_LEVEL" == "debug" ]] && echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Check if email was already processed recently
is_recently_processed() {
    local email_id="$1"
    local status_file="/tmp/email_${email_id}_status"
    
    # If status file exists and is less than 1 hour old, skip
    if [[ -f "$status_file" ]] && [[ $(find "$status_file" -mmin -60 2>/dev/null) ]]; then
        return 0  # Recently processed
    fi
    
    return 1  # Not recently processed
}

# Process pending email decisions from human
process_human_decisions() {
    local pending_dir="$SECURITY_DIR/pending"
    mkdir -p "$pending_dir"
    
    # Check for any approval/quarantine commands from recent messages
    # This would integrate with OpenClaw's message history if available
    
    # For now, check for simple status files
    for status_file in /tmp/email_*_status; do
        [[ -f "$status_file" ]] || continue
        
        local email_id
        email_id=$(basename "$status_file" | sed 's/email_\(.*\)_status/\1/')
        
        local status
        status=$(cat "$status_file")
        
        case "$status" in
            "APPROVED")
                success "✅ Human approved email $email_id - processing normally"
                echo "SAFE" > "$status_file"
                ;;
            "QUARANTINED")
                log "🔒 Human quarantined email $email_id"
                # Move to quarantine if not already there
                himalaya message move "$email_id" "$QUARANTINE_FOLDER" >/dev/null 2>&1 || true
                ;;
            "PENDING")
                # Check if pending too long (2 hours)
                if [[ $(find "$status_file" -mmin +120 2>/dev/null) ]]; then
                    warn "⏰ Email $email_id pending review for 2+ hours - auto-quarantining"
                    himalaya message move "$email_id" "$QUARANTINE_FOLDER" >/dev/null 2>&1 || true
                    echo "QUARANTINED" > "$status_file"
                fi
                ;;
        esac
    done
}

# Main processing function
process_emails() {
    log "Starting email security scan..."
    
    # Process any pending human decisions first
    process_human_decisions
    
    # Get unread emails
    local unread_emails
    if ! unread_emails=$(himalaya envelope list --format json 2>/dev/null); then
        error "Failed to fetch email list - check Himalaya configuration"
        return 1
    fi
    
    # Filter for truly unread emails
    local new_emails
    new_emails=$(echo "$unread_emails" | jq -r '.[] | select(.flags.seen == false) | .id' 2>/dev/null || echo "")
    
    if [[ -z "$new_emails" ]]; then
        debug "No new emails to process"
        return 0
    fi
    
    local processed_count=0
    local quarantined_count=0
    local pending_count=0
    
    while IFS= read -r email_id; do
        [[ -n "$email_id" ]] || continue
        
        # Skip if recently processed
        if is_recently_processed "$email_id"; then
            debug "Skipping recently processed email: $email_id"
            continue
        fi
        
        log "Processing email: $email_id"
        
        # Call the security analysis script
        if "$SCRIPT_DIR/email-security-scan.sh" analyze-email "$email_id"; then
            # Check result status
            local status_file="/tmp/email_${email_id}_status"
            if [[ -f "$status_file" ]]; then
                local status
                status=$(cat "$status_file")
                case "$status" in
                    "SAFE")
                        ((processed_count++))
                        ;;
                    "QUARANTINED") 
                        ((quarantined_count++))
                        ;;
                    "PENDING")
                        ((pending_count++))
                        ;;
                esac
            fi
        else
            warn "Failed to analyze email $email_id"
        fi
        
        # Small delay to avoid overwhelming systems
        sleep 2
        
    done <<< "$new_emails"
    
    # Summary report
    if [[ $((processed_count + quarantined_count + pending_count)) -gt 0 ]]; then
        echo ""
        success "📊 Email Processing Summary:"
        echo "  ✅ Processed safely: $processed_count"
        echo "  🔒 Quarantined: $quarantined_count"  
        echo "  🟡 Pending review: $pending_count"
        echo ""
        
        # Log summary to daily report
        local daily_log="$SECURITY_DIR/logs/daily-$(date +%Y-%m-%d).log"
        echo "$(date '+%H:%M:%S') | Summary: Safe=$processed_count, Quarantined=$quarantined_count, Pending=$pending_count" >> "$daily_log"
    fi
}

# Generate daily security report
generate_daily_report() {
    local today
    today=$(date +%Y-%m-%d)
    local daily_log="$SECURITY_DIR/logs/daily-$today.log"
    
    if [[ ! -f "$daily_log" ]]; then
        log "No email activity today"
        return 0
    fi
    
    echo "📧 Email Security Report - $today"
    echo "================================"
    
    # Count totals from log
    local total_safe=0
    local total_quarantined=0  
    local total_pending=0
    
    while IFS='|' read -r timestamp summary; do
        [[ -n "$summary" ]] || continue
        
        local safe_count
        safe_count=$(echo "$summary" | grep -o 'Safe=[0-9]*' | cut -d'=' -f2 || echo "0")
        local quarantined_count
        quarantined_count=$(echo "$summary" | grep -o 'Quarantined=[0-9]*' | cut -d'=' -f2 || echo "0")
        local pending_count
        pending_count=$(echo "$summary" | grep -o 'Pending=[0-9]*' | cut -d'=' -f2 || echo "0")
        
        ((total_safe += safe_count))
        ((total_quarantined += quarantined_count))  
        ((total_pending += pending_count))
        
    done < "$daily_log"
    
    echo "✅ Processed safely: $total_safe emails"
    echo "🔒 Threats quarantined: $total_quarantined emails"
    echo "🟡 Pending review: $total_pending emails"
    
    # Calculate efficiency
    local total_emails=$((total_safe + total_quarantined + total_pending))
    if [[ $total_emails -gt 0 ]]; then
        local safe_percent=$((total_safe * 100 / total_emails))
        echo "📈 Auto-processing rate: ${safe_percent}% (target: >80%)"
    fi
    
    # Recent threats
    if [[ $total_quarantined -gt 0 ]]; then
        echo ""
        echo "🚨 Recent Threats:"
        grep "QUARANTINED" "$SECURITY_DIR/logs/email-analysis.log" | tail -3 | while IFS='|' read -r timestamp email_id sender risk analysis; do
            echo "  - $sender: $(echo $analysis | head -c 60)..."
        done
    fi
}

# Cleanup old logs and temp files
cleanup() {
    log "Cleaning up old files..."
    
    # Remove old temp status files (older than 24 hours)
    find /tmp -name "email_*_status" -mtime +1 -delete 2>/dev/null || true
    
    # Rotate logs if they exist
    if [[ -d "$SECURITY_DIR/logs" ]]; then
        # Keep logs for configured retention period
        local retain_days="${RETAIN_LOGS_DAYS:-30}"
        find "$SECURITY_DIR/logs" -name "daily-*.log" -mtime +$retain_days -delete 2>/dev/null || true
        find "$SECURITY_DIR/logs" -name "email-analysis.log.*" -mtime +$retain_days -delete 2>/dev/null || true
        
        # Rotate main log if it's getting large (>10MB)
        local main_log="$SECURITY_DIR/logs/email-analysis.log"
        if [[ -f "$main_log" ]] && [[ $(stat -f%z "$main_log" 2>/dev/null || stat -c%s "$main_log" 2>/dev/null || echo "0") -gt 10485760 ]]; then
            mv "$main_log" "${main_log}.$(date +%Y%m%d-%H%M%S)"
            success "Rotated large log file"
        fi
    fi
}

# Check system health
health_check() {
    echo "🛡️ Email Security Health Check"
    echo "=============================="
    
    # Ollama connectivity
    if curl -s "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
        echo "✅ Ollama: Connected"
    else
        echo "❌ Ollama: Connection failed"
        return 1
    fi
    
    # Himalaya
    if himalaya account list >/dev/null 2>&1; then
        echo "✅ Himalaya: Configured"
    else
        echo "❌ Himalaya: Not configured"
        return 1
    fi
    
    # OpenClaw  
    if command -v openclaw >/dev/null 2>&1; then
        echo "✅ OpenClaw: Available"
    else
        echo "⚠️  OpenClaw: Not available (using file logging)"
    fi
    
    # Configuration
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "✅ Config: Found"
    else
        echo "❌ Config: Missing"
        return 1
    fi
    
    # Recent activity
    local log_file="$SECURITY_DIR/logs/email-analysis.log"
    if [[ -f "$log_file" ]]; then
        local recent_entries
        recent_entries=$(tail -10 "$log_file" | wc -l)
        echo "📊 Recent activity: $recent_entries log entries"
    else
        echo "📊 Recent activity: No logs yet"
    fi
    
    return 0
}

# Main script logic
main() {
    case "${1:-}" in
        "--scan-unread"|"scan")
            process_emails
            ;;
        "--report"|"report")
            generate_daily_report
            ;;
        "--health"|"health")
            health_check
            ;;
        "--cleanup"|"cleanup")
            cleanup
            ;;
        "--daemon"|"daemon")
            log "Starting email security daemon..."
            while true; do
                process_emails
                sleep 600  # 10 minutes
            done
            ;;
        *)
            echo "Usage: $0 {scan|report|health|cleanup|daemon}"
            echo ""
            echo "Commands:"
            echo "  scan     - Process unread emails for security threats"
            echo "  report   - Generate daily security report"  
            echo "  health   - Check system health and connectivity"
            echo "  cleanup  - Remove old logs and temp files"
            echo "  daemon   - Run continuously (every 10 minutes)"
            echo ""
            echo "Cron setup (recommended):"
            echo "  */10 * * * * $0 scan >/dev/null 2>&1"
            echo ""
            echo "Examples:"
            echo "  $0 scan"
            echo "  $0 report"
            echo "  $0 health"
            exit 1
            ;;
    esac
}

# Ensure required directories exist
mkdir -p "$SECURITY_DIR"/{logs,quarantine,patterns}

# Run main function
main "$@"