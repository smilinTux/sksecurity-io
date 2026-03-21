# SKSecurity - Email Prescreening Docker Image
# Multi-stage build for production deployment

FROM ubuntu:24.04 AS base

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York

# Install base dependencies
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    cron \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Stage 2: Build with tools
FROM base AS builder

# Install additional build tools and development dependencies
RUN apt-get update && apt-get install -y \
    git \
    wget \
    build-essential \
    libssl-dev \
    libffi-dev \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Himalaya (email CLI) - using specific version URL
RUN curl -sSL "https://github.com/soywod/himalaya/releases/download/v1.8.0/himalaya-linux.tar.gz" | \
    tar -xzf - -C /tmp && \
    mv /tmp/himalaya /usr/local/bin/

# Stage 3: Production image
FROM base AS production

LABEL maintainer="Lumina <lumina@smilintux.org>"
LABEL org.opencontainers.image.title="SKSecurity Email Prescreening"
LABEL org.opencontainers.image.description="AI-powered email security for agents"
LABEL org.opencontainers.image.source="https://github.com/smilinTux/sksecurity.io"

# Copy Himalaya from builder
COPY --from=builder /usr/local/bin/himalaya /usr/local/bin/himalaya

# Create security user
RUN useradd -m -s /bin/bash sksecurity && \
    mkdir -p /home/sksecurity/.openclaw/skills/email-prescreening && \
    mkdir -p /home/sksecurity/.openclaw/security/{logs,quarantine,patterns} && \
    chown -R sksecurity:sksecurity /home/sksecurity

# Copy skill files
COPY --chown=sksecurity:sksecurity skills/email-prescreening/*.sh /home/sksecurity/.openclaw/skills/email-prescreening/
COPY --chown=sksecurity:sksecurity skills/email-prescreening/patterns/ /home/sksecurity/.openclaw/security/patterns/

# Create config file using printf to avoid heredoc issues
RUN printf '%s\n' \
    '# SKSecurity Email Prescreening Configuration' \
    'OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"' \
    'SECURITY_MODEL="qwen2.5:7b"' \
    'RISK_SENSITIVITY="medium"' \
    'EMAIL_ACCOUNT="default"' \
    'ALERT_METHOD="telegram"' \
    'AUTO_QUARANTINE_HIGH_RISK="true"' \
    'ANALYSIS_TIMEOUT="30"' \
    'MAX_CONTENT_LENGTH="10000"' \
    'LOG_LEVEL="info"' \
    > /home/sksecurity/.openclaw/security/email-prescreening.conf

# Install Python packages (requirements.txt)
COPY --chown=sksecurity:sksecurity requirements.txt /tmp/requirements.txt
RUN if [ -f /tmp/requirements.txt ]; then \
    pip3 install --no-cache-dir -r /tmp/requirements.txt; \
    rm /tmp/requirements.txt; \
    fi

# Install NPM packages (package.json)
COPY --chown=sksecurity:sksecurity package.json /tmp/package.json
RUN if [ -f /tmp/package.json ]; then \
    npm install --prefix /tmp --no-audit --no-fund && \
    cp -r /tmp/node_modules /home/sksecurity/.openclaw/ && \
    rm -rf /tmp/package.json /tmp/node_modules; \
    fi

# Set permissions
RUN chmod +x /home/sksecurity/.openclaw/skills/email-prescreening/*.sh && \
    chown -R sksecurity:sksecurity /home/sksecurity/.openclaw

# Create entrypoint script using RUN with explicit script
RUN echo '#!/bin/bash' > /entrypoint.sh && \
    echo 'set -e' >> /entrypoint.sh && \
    echo 'echo "🛡️ SKSecurity Email Prescreening Starting..."' >> /entrypoint.sh && \
    echo 'if [ -z "$OLLAMA_HOST" ]; then export OLLAMA_HOST="http://ollama:11434"; fi' >> /entrypoint.sh && \
    echo 'echo "OLLAMA_HOST: $OLLAMA_HOST"' >> /entrypoint.sh && \
    echo 'echo "Testing Ollama connectivity..."' >> /entrypoint.sh && \
    echo 'if curl -s "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then' >> /entrypoint.sh && \
    echo '    echo "✅ Ollama reachable"' >> /entrypoint.sh && \
    echo '    if curl -s "$OLLAMA_HOST/api/tags" | jq -r ".models[].name" | grep -q "qwen2.5:7b"; then' >> /entrypoint.sh && \
    echo '        echo "✅ Security model available"' >> /entrypoint.sh && \
    echo '    else' >> /entrypoint.sh && \
    echo '        echo "⚠️ Security model not found. Run: ollama pull qwen2.5:7b"' >> /entrypoint.sh && \
    echo '    fi' >> /entrypoint.sh && \
    echo 'else' >> /entrypoint.sh && \
    echo '    echo "⚠️ Ollama not reachable. Set OLLAMA_HOST environment variable"' >> /entrypoint.sh && \
    echo 'fi' >> /entrypoint.sh && \
    echo 'echo "Starting cron daemon..."' >> /entrypoint.sh && \
    echo 'cron' >> /entrypoint.sh && \
    echo '(crontab -u sksecurity -l 2>/dev/null || echo ""); echo "*/10 * * * * /home/sksecurity/.openclaw/skills/email-prescreening/secure-email-processor.sh --scan-unread >> /home/sksecurity/.openclaw/security/logs/cron.log 2>&1" | crontab -u sksecurity -' >> /entrypoint.sh && \
    echo 'echo "✅ SKSecurity Email Prescreening is running"' >> /entrypoint.sh && \
    echo 'echo "Logs: /home/sksecurity/.openclaw/security/logs/"' >> /entrypoint.sh && \
    echo 'tail -f /dev/null' >> /entrypoint.sh

RUN chmod +x /entrypoint.sh

WORKDIR /home/sksecurity
USER sksecurity

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
