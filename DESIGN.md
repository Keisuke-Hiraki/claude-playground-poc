# Claude Code 勉強会プレイグラウンド — 設計ドキュメント

## 背景・目的

社内勉強会「Claude Code入門勉強会シリーズ」の参加者に、環境構築なしで Claude Code を試せる共通プレイグラウンドを提供する。要件は以下の3点:

- Cognito によるユーザー管理
- コンテナ上で Claude Code を実行
- PTY を割り当て、ブラウザからユーザー端末として操作できる Web アプリ

前提条件（勉強会主催者ヒアリング済み）:

| 項目 | 決定事項 |
|---|---|
| Claude 認証方式 | Amazon Bedrock（IAM タスクロール、API キー配布なし） |
| 想定規模 | 同時 10〜30 人 |
| ワークスペースの永続性 | 使い捨て（セッション終了でコンテナごと破棄） |

## 結論: 実現可能

Cognito → ALB（Cognito 認証アクション） → xterm.js/WebSocket → ユーザーごとのコンテナ（ttyd + Claude Code on Bedrock）という構成は、各要素とも実績のある組み合わせで構築できる。

- **Claude Code は Bedrock 利用時、対話的 OAuth ログインが不要。** `CLAUDE_CODE_USE_BEDROCK=1` を設定すれば AWS SDK 標準の認証チェーン（ECS タスクロールを自動取得）でヘッドレス起動できる。
  出典: https://code.claude.com/docs/en/amazon-bedrock
- **コンテナでの実行には公式リファレンスがある。** `anthropics/claude-code/.devcontainer/`（Dockerfile + `init-firewall.sh` によるエグレス許可リスト、`NET_ADMIN`/`NET_RAW` capability が必要）をベースイメージの参考にできる。
- 唯一エンジニアリングが重くなるのは「認証済みユーザー A を A のコンテナへ届けるセッションルーティング」。10〜30 人規模であれば動的プロビジョニングは不要で、事前起動 + 軽量ゲートウェイで十分シンプルに実現できる。

## 本番想定アーキテクチャ

```
参加者ブラウザ
  │ HTTPS / WSS
  ▼
CloudFront + S3 (xterm.js SPA)          ← 静的フロント（本PoCでは省略、ttydが自前で配信）
  │
ALB (authenticate-cognito リスナーアクション)
  │ ← Cognito Hosted UI でログイン、ALB がセッション Cookie を検証
  ▼
セッションゲートウェイ (Fargate, Node.js)
  │ ← ALB が付与する x-amzn-oidc-data (JWT) から user id を取得し
  │    DynamoDB の user→コンテナIP マッピングで WebSocket をプロキシ
  ▼
ユーザー別コンテナ (ECS Fargate, 事前プロビジョニング)
  - ttyd (PTY 割当・Web 端末)
  - Claude Code (CLAUDE_CODE_USE_BEDROCK=1, タスクロール)
  - init-firewall.sh ベースのエグレス制限
  ▼
Amazon Bedrock (Claude Sonnet, 日本国内クロスリージョン推論プロファイル)
```

### 設計判断

- **ALB 認証 + ゲートウェイ1段**を採用する。ユーザーごとに ALB ターゲットグループを作る方式は、ALB のターゲットグループ上限（1 ALB あたり 100、引き上げ不可）に抵触しやすく運用も重い。10〜30 人規模ならゲートウェイの WebSocket プロキシで十分。
- **事前プロビジョニング**: 勉強会開始前に人数分のタスクを起動し、Cognito ユーザーに割り当てる。オンデマンド起動（起動待ち 30〜60 秒）を避ける。ユーザー→タスク IP のマッピングは DynamoDB に保持し、ECS タスク状態変更の EventBridge イベントで更新する。
- **PTY サーバーは ttyd** を採用する（https://github.com/tsl0922/ttyd 、C実装・xterm.js内蔵・約12k stars、最新版 v1.7.7）。`-W`（書き込み許可。デフォルトは read-only）と、上流プロキシの認証済みヘッダーを信頼する `-H` オプションが ALB 連携パターンにそのまま合う。wetty はリリースが約3年停滞しており不採用。
- **ゲートウェイでの JWT 検証**: ALB が付与する `x-amzn-oidc-data` の署名を `https://public-keys.auth.elb.{region}.amazonaws.com/{kid}` の公開鍵で検証する（AWS公式の要件。ヘッダー偽装対策として必須）。
- **モデル**: `jp.anthropic.claude-sonnet-4-5-20250929-v1:0`（東京・大阪間の国内完結クロスリージョン推論。日本のデータレジデンシー要件に適合）。
  出典: https://aws.amazon.com/blogs/machine-learning/introducing-amazon-bedrock-cross-region-inference-for-claude-sonnet-4-5-and-haiku-4-5-in-japan-and-australia/
  より新しいモデル世代の東京対応可否は実装時に `aws bedrock list-inference-profiles --region ap-northeast-1` で確認する。

### ⚠️ 要検証事項: ALB 認証 × WebSocket

ALB は WebSocket アップグレード要求も通常の HTTP リクエストとして扱い、認証済みセッション Cookie（`AWSELBAuthSessionCookie`）は毎リクエスト検証される仕組みのため、Cookie を保持した状態での WS アップグレードは通る「はず」である。ただし **「ALB 認証機能が WebSocket で動作する」という AWS 公式ドキュメントの明文は見つかっていない**（コミュニティでの利用実績は多数確認）。本番実装に着手する前に、実際の ALB + Cognito 環境での確認を強く推奨する。

また、WebSocket API はブラウザ側で 302 リダイレクトを追えないため、**初回ログインは通常のページロードで完了させてから WebSocket 接続を開始する**設計とする。セッション失効時も WS は汎用エラーしか返さないため、ページ側で定期的な認証済み XHR によりセッション失効を検知し、再ログインを促す。

## セキュリティ設計

参加者はセキュリティコンサルタントであり、構成そのものが監査対象になりうる前提で設計する。

- コンテナはユーザー間でタスク単位に分離（Fargate はタスク＝軽量VM相当の分離境界）。非 root ユーザーで実行。
- **最重要の脅威モデル**: コンテナ内シェルを持つ参加者は誰でもタスクロールの認証情報を取得できる。そのため IAM タスクロールは `bedrock:InvokeModel*` を対象モデルの ARN のみに絞り込み、他の権限を一切持たせない。
- エグレスは `init-firewall.sh` 方式の許可リスト（Bedrock/STS エンドポイント、github.com、registry.npmjs.org 等）で制限する。ただし公式スクリプトには DNS トンネリングによる回避の既知課題がある（`anthropics/claude-code` issue #36907, #35197）。厳密なエグレス制御が必要な場合は VPC レベル（Route 53 Resolver DNS Firewall やネットワークファイアウォール）で補強する。
- セッション TTL: 勉強会終了時刻に全タスクを自動停止する（EventBridge スケジュール）。
- コスト暴走対策: Bedrock 呼び出しに対する CloudWatch アラームと AWS Budgets を設定する。
- コンテナ内の Claude Code は使い捨て・サンドボックス前提のため、`--dangerously-skip-permissions` 相当の緩い権限設定でよい。ただしこれは「使い捨てコンテナだから許容する」トレードオフであり、永続化構成に転用する場合は再検討が必要。
- 利用状況の可視化: Claude Code の OTEL テレメトリ（`CLAUDE_CODE_ENABLE_TELEMETRY=1`）によるユーザー別メトリクス収集は実装時に別途検証する。

## コスト概算（勉強会1回・30人・2時間、ap-northeast-1）

- **Fargate**: 1 vCPU + 2GB ≈ $0.062/時 × 30 タスク × 2時間 ≈ **$3.7**（誤差レベル。使い捨て運用のため常時稼働コストは発生しない）
- **Bedrock (Claude Sonnet 4.5)**: $3/100万入力トークン・$15/100万出力トークン。ハンズオン利用で1人あたり $2〜8/セッション程度と想定 → 30人で **$60〜240**
- **合計: 1回あたり概ね $70〜250（1〜4万円程度）。コストはほぼ Bedrock トークン利用が支配する。**
- 注記: Fargate 単価は AWS 公式料金ページが動的レンダリングのため二次情報で照合、`jp.` プロファイルの地域プライシングの有無は未確認。実装時に AWS Pricing Calculator で再確認すること。

出典: https://aws.amazon.com/fargate/pricing/ , https://aws.amazon.com/bedrock/pricing/

## 代替案（検討済み・不採用）

- **GitHub Codespaces + 公式 devcontainer**: 環境構築ゼロで最速だが、参加者ごとの GitHub アカウント/課金と Bedrock 認証の注入が煩雑。
- **Coder / code-server**: セッション管理・端末・ワークスペース管理が既製品として揃っている。要件は満たせるが自前運用対象が増える。将来の規模拡大時の乗り換え先候補。
- **claude.ai/code (Claude Code on the Web)**: 個人アカウント前提のため、今回の「共通プレイグラウンド」要件には合わない。

## PoC の検証状況

ローカル docker-compose 版・AWS 本番相当構成（Terraform）の両方について、実際に AWS 上で動かして確認済み。

**確認済み**:

- `docker compose up --build` によるコンテナビルド・起動、`/login?user=alice`・`?user=bob` でのユーザー別 WebSocket ルーティング。
- AWS 本番相当構成（Cognito Hosted UI ログイン → ALB `authenticate-cognito` → ALB 署名済み ID トークンの検証 → ECS `RunTask` によるユーザー専用タスクの動的起動 → WebSocket プロキシ）を実際のブラウザ操作で E2E 確認。
- 動的起動されたコンテナ内で `claude -p` を実行し、Amazon Bedrock 経由の実際の応答を確認。
- Cognito 自己登録の許可メールドメイン制限（Pre-SignUp Lambda）が許可外ドメインを拒否し、許可ドメインを通過させることを確認。
- 利用可能時間帯外のログイン試行が 403 で拒否されることを確認。
- コンテナ内バナー（日本語、利用時間帯・セッション時間上限・ストレージ上限・利用可能モデルバージョンの明記）が文字化けなく表示されることを確認。

**判明した既知の落とし穴**（README.md にも記載）:

- Claude Code は Bedrock 利用時でも `api.anthropic.com` 等へ到達しようとするため、VPC 内に一般的なインターネット経路（NAT Gateway）がないと初回リクエストが長時間ハングする。
- 利用対象の Bedrock モデルは、リージョン/アカウントごとに AWS Marketplace 利用規約への同意（`create-foundation-model-agreement`）が必要。同意していない場合のエラーはリトライを繰り返した末に表示されるため、原因の特定に時間がかかりやすい。

**未検証**:

- 複数ユーザーが同時にアクセスした場合の挙動（同時実行時のリソース競合・ECS 起動レート制限等）。
- セッション時間上限・利用可能時間帯終了による自動停止が実際に発火するタイミングの精度（実装上は `setTimeout` で制御しているが、長時間の実測は未実施）。
- OTEL テレメトリによるユーザー別コスト可視化。
