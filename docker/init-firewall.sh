#!/bin/bash
# Egress allowlist for the per-user playground container.
# Adapted from the official reference at
# https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
# for a Bedrock-backed setup (no api.anthropic.com egress needed).
#
# NOTE (PoC limitation, see README): this script relies on DNS-name resolution
# at setup time and is known to have a DNS-tunneling gap upstream
# (anthropics/claude-code issues #36907, #35197). For production, back this
# up with a VPC-level control (Route 53 Resolver DNS Firewall / network FW)
# rather than relying on this script alone.
set -euo pipefail

ALLOWED_DOMAINS=(
    "github.com"
    "objects.githubusercontent.com"
    "registry.npmjs.org"
    "bedrock-runtime.${AWS_REGION:-ap-northeast-1}.amazonaws.com"
    "bedrock.${AWS_REGION:-ap-northeast-1}.amazonaws.com"
    "sts.${AWS_REGION:-ap-northeast-1}.amazonaws.com"
)

sudo ipset create allowed-domains hash:ip -exist

for domain in "${ALLOWED_DOMAINS[@]}"; do
    ips=$(dig +short "$domain" A | grep -E '^[0-9.]+$' || true)
    for ip in $ips; do
        sudo ipset add allowed-domains "$ip" -exist
    done
done

sudo iptables -F OUTPUT || true
sudo iptables -A OUTPUT -o lo -j ACCEPT
sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
sudo iptables -A OUTPUT -j DROP

echo "init-firewall: egress restricted to: ${ALLOWED_DOMAINS[*]}"
