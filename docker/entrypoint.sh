#!/bin/bash
# Container entrypoint: optionally lock down egress, then expose a web
# terminal (ttyd) that drops the user into a shell with Claude Code ready.
set -euo pipefail

if [ "${ENABLE_FIREWALL:-false}" = "true" ]; then
    sudo /usr/local/bin/init-firewall.sh
fi

echo "playground container ready: user=${PLAYGROUND_USER:-unknown} model=${ANTHROPIC_MODEL:-unset}"

cat > /home/playground/.playground_banner <<EOF
================================================================
 Claude Code 勉強会サンドボックス環境 — 利用前に必ずお読みください
================================================================
 * これは勉強会用の使い捨てサンドボックス環境です。セッション終了後は
   何も残りません。必要なものは時間内に別の場所へ保存してください。
 * 利用可能時間帯: JST ${WINDOW_START_JST:-10:00}〜${WINDOW_END_JST:-11:00}
   1回のセッションの利用時間上限: ${SESSION_MAX_MINUTES:-45}分
   （利用可能時間帯の終了時刻の、どちらか早いほうでコンテナは自動停止します）
 * ストレージ上限: ${STORAGE_LIMIT_GIB:-20}GiB（他の参加者とは共有されない、
   あなた専用の領域です）
 * 利用可能なモデル: Amazon Bedrock経由の以下のみです。
   Claude Opus 4.6 / Claude Sonnet 5 / Claude Haiku 4.5
================================================================
EOF

# Printed once per shell login (bash -l sources .bash_profile).
cat > /home/playground/.bash_profile <<'EOF'
cat ~/.playground_banner
EOF

# -W: allow input (ttyd defaults to read-only). Identity/authN is handled
# one layer up by the gateway (mirrors ALB terminating auth before traffic
# reaches this container) — see gateway/server.js.
exec ttyd -W -p 7681 bash -l
