# Claude Code + ttyd container image for the workshop playground PoC.
# Loosely based on the official devcontainer reference:
# https://github.com/anthropics/claude-code/tree/main/.devcontainer
FROM node:20-slim

ARG TTYD_VERSION=1.7.7

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        git \
        procps \
        iptables \
        ipset \
        dnsutils \
        sudo \
        locales \
    && sed -i '/ja_JP.UTF-8/s/^# //' /etc/locale.gen \
    && locale-gen ja_JP.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=ja_JP.UTF-8 \
    LANGUAGE=ja_JP:ja \
    LC_ALL=ja_JP.UTF-8

# Install ttyd (static binary release) — provides the browser-facing PTY server.
RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
         amd64) TTYD_ARCH=x86_64 ;; \
         arm64) TTYD_ARCH=aarch64 ;; \
         *) echo "unsupported arch: $ARCH" && exit 1 ;; \
       esac \
    && curl -fsSL -o /usr/local/bin/ttyd \
         "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
    && chmod +x /usr/local/bin/ttyd

# Install Claude Code CLI.
RUN npm install -g @anthropic-ai/claude-code

# Non-root workspace user (disposable container: no persistent volume expected).
RUN useradd -m -s /bin/bash playground \
    && echo "playground ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/playground

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

# Pins the workshop to the three Bedrock models approved for this playground.
# The IAM task role is the actual enforcement point (InvokeModel is scoped to
# just these models); this file just makes the intended default explicit.
RUN mkdir -p /home/playground/.claude
COPY settings.json /home/playground/.claude/settings.json
RUN chown -R playground:playground /home/playground/.claude

USER playground
WORKDIR /home/playground
ENV HOME=/home/playground

EXPOSE 7681
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
