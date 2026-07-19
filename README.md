# Claude Code 勉強会プレイグラウンド — PoC

Cognito でユーザー管理し、コンテナ上で動く Claude Code に PTY 経由でブラウザからアクセスする「共通プレイグラウンド」の実現可能性検証 PoC。

設計の背景・本番アーキテクチャ・セキュリティ/コスト検討は [DESIGN.md](./DESIGN.md) を参照。

このディレクトリはローカル Docker で以下を確認するための最小構成:

- Claude Code + ttyd を同梱したコンテナイメージがビルドできること
- ゲートウェイが「ログインユーザー → 専用コンテナ」への WebSocket ルーティングを行えること（本番の ALB + Cognito をモック）

Cognito / ALB は含まれない。ゲートウェイの `/login?user=<name>` が「Cognito Hosted UI ログイン完了後に ALB がセッション Cookie を発行する」動作の代わりを果たす。

## 構成

```
docker/              Claude Code + ttyd のコンテナイメージ（参加者用）
gateway/             セッションゲートウェイ（ユーザー→コンテナのWebSocketプロキシ）
docker-compose.yml   ローカル確認用: alice/bob 用コンテナ2台 + gateway
terraform/           AWS 本番相当構成一式（Cognito, ALB, ECS Fargate, NAT Gateway 等）
lambda/pre-signup/   Cognito 自己登録の許可メールドメイン制限（Pre-SignUp トリガー）
scripts/             Bedrock モデルの Marketplace 同意、イメージビルド&push
```

## 環境変数・設定値の管理場所

このリポジトリでは設定値の種類によって管理場所が3つに分かれている。

| 管理場所 | 対象 | コミット対象か |
|---|---|---|
| `.env`（`docker-compose.yml` が読む） | ローカル docker-compose 版の AWS 認証情報・モデル指定 | ✗（`.gitignore` 対象。`.env.example` をコピーして作成） |
| `terraform/terraform.tfvars` | 本番相当構成（AWS）のデプロイ設定一式 | ✗（`.gitignore` 対象。`terraform.tfvars.example` をコピーして作成） |
| シェル環境変数（`scripts/*.sh` 実行時に指定） | `AWS_PROFILE`・`AWS_REGION` 等、スクリプト実行時のみ使うもの | — （シェルで都度指定） |

### `.env`（ローカル docker-compose 版）

`cp .env.example .env` して以下を記入する。

| 変数 | 説明 | 既定値 |
|---|---|---|
| `AWS_REGION` | Bedrock を呼ぶリージョン | `ap-northeast-1` |
| `ANTHROPIC_MODEL` | 使用する Bedrock モデル（推論プロファイル ID） | `jp.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` | `bedrock:InvokeModel` 権限を持つ AWS 認証情報。未設定でもビルド・ルーティング確認は可能（`claude` の実応答のみ確認できない） | 空 |
| `ENABLE_FIREWALL` | `true` にすると `docker/init-firewall.sh` のエグレス許可リストをコンテナ内で有効化 | `false` |

### `terraform/terraform.tfvars`（本番相当構成）

`cp terraform/terraform.tfvars.example terraform/terraform.tfvars` して以下を記入する。定義・既定値の全量は [`terraform/variables.tf`](./terraform/variables.tf) を参照。

必須（既定値なし、必ず自分の環境の値に書き換える）:

| 変数 | 説明 |
|---|---|
| `vpc_id` | デプロイ先の既存 VPC（Internet Gateway 付き） |
| `public_subnet_ids` | ALB・NAT Gateway 用のパブリックサブネット（2つ以上） |
| `private_subnet_az` | ゲートウェイ・参加者コンテナ用に新規作成する private subnet の AZ |
| `domain_name` | プレイグラウンドを公開する FQDN |
| `route53_zone_id` | `domain_name` が属する Route53 ホストゾーン ID |
| `allowed_signup_email_domains` | Cognito 自己登録を許可するメールドメイン（例: `["example.com"]`）。既定のサンプル値のままでは誰も自己登録できない |

任意（既定値あり、必要な場合のみ上書き）:

| 変数 | 説明 | 既定値 |
|---|---|---|
| `aws_region` | デプロイ先リージョン | `ap-northeast-1` |
| `aws_profile` | 使用する AWS CLI プロファイル | なし（デフォルトの認証チェーン） |
| `project_name` | ECS クラスタ・IAM ロール・Cognito ユーザープール・Pre-SignUp Lambda の名前接頭辞 | `claude-playground-poc` |
| `image_name_prefix` | ECR リポジトリ・ECS タスク定義 family の名前接頭辞 | `claude-playground` |
| `network_resource_prefix` | ALB・ターゲットグループ・セキュリティグループの名前接頭辞 | `playground` |
| `ecs_task_execution_role_name` | 既存の ECS タスク実行ロール名（イメージ pull・ログ送信用） | `ecsTaskExecutionRole` |
| `access_window_start_jst` / `access_window_end_jst` | ログイン受付時間帯（JST） | `10:00` / `11:00` |
| `session_max_minutes` | 1セッションあたりの利用時間上限（分） | `45` |
| `storage_limit_gib` | コンテナ内バナーに表示するストレージ上限（表示用。タスク定義側は Fargate 既定の 20GiB のまま） | `20` |
| `bedrock_model_ids` / `bedrock_model_prefix` | 利用可能な Bedrock モデルとその推論プロファイル接頭辞 | Opus/Sonnet/Haiku 各最新版、`global` |
| `user_task_cpu` / `user_task_memory` | 参加者コンテナの Fargate CPU/メモリ | `1024` / `2048` |
| `gateway_image_tag` / `user_image_tag` | デプロイするイメージタグ | `latest` |
| `enable_container_firewall` | コンテナ内エグレス許可リストの有効化 | `false` |
| `log_retention_days` | CloudWatch Logs の保持期間 | `3` |

`image_name_prefix`・`network_resource_prefix`・`ecs_task_execution_role_name` の3つは、既存 AWS アカウント上のリソース名がプロジェクト全体で単一の接頭辞に統一されていない場合に既存リソースへ合わせるための変数。新規に環境を作る場合は特に上書きする必要はない。

### スクリプト実行時のシェル環境変数（`scripts/*.sh`）

`terraform.tfvars` とは別に、デプロイ用スクリプトはコマンド実行時に環境変数で指定する。`terraform.tfvars` の値と食い違うと ECR リポジトリ名や ECS クラスタ名が一致せず失敗するので、上記で設定した `image_name_prefix`・`project_name` と揃えること。

| 変数 | 使用スクリプト | 説明 | 既定値 |
|---|---|---|---|
| `AWS_PROFILE` | 両方 | 使用する AWS CLI プロファイル | 未設定時はデフォルトの認証チェーン |
| `AWS_REGION` | 両方 | 対象リージョン | `ap-northeast-1` |
| `IMAGE_NAME_PREFIX` | `build_and_push.sh` | push 先 ECR リポジトリ名の接頭辞。`terraform.tfvars` の `image_name_prefix` と一致させる | `claude-playground` |
| `PROJECT_NAME` | `build_and_push.sh` | 再デプロイコマンドの出力に使う ECS クラスタ名。`terraform.tfvars` の `project_name` と一致させる | `claude-playground-poc` |

## 起動手順

1. AWS 認証情報を用意する（対象 Bedrock モデルへの `bedrock:InvokeModel` 権限が必要）。無くてもビルド・ルーティング確認は可能（`claude` コマンドの実応答のみ確認できない）。

   ```bash
   cp .env.example .env
   # .env にAWS_ACCESS_KEY_ID等を記入
   ```

2. ビルド & 起動

   ```bash
   docker compose up --build
   ```

3. ブラウザで以下にアクセスし、ユーザーごとに別コンテナへ振り分けられることを確認する。

   - `http://localhost:8080/login?user=alice` → 自動的に `/` へリダイレクトし、alice 用コンテナの ttyd 端末が開く
   - 別のブラウザ（またはシークレットウィンドウ）で `http://localhost:8080/login?user=bob` → bob 用コンテナの端末が開く

   端末が開いたら `claude --version` や `claude` で起動確認する。AWS 認証情報が有効であれば Bedrock 経由で通常どおり対話できる。

4. 後片付け

   ```bash
   docker compose down
   ```

## 既知の制約（ローカル docker-compose 版）

- ここでの `/login` はユーザー名を渡すだけの平文モックであり、認証は一切行っていない（本番相当構成では ALB の `authenticate-cognito` アクションに置き換わる。下記参照）。
- ユーザー→コンテナのマッピングは `gateway/users.json` の静的ファイル（本番相当構成では ECS の動的タスク起動に置き換わる）。
- コンテナは `docker-compose.yml` に静的に2台定義。
- エグレス制限（`docker/init-firewall.sh`）はデフォルト無効（`ENABLE_FIREWALL=false`）。有効化する場合は `cap_add: NET_ADMIN, NET_RAW` が必要（compose には設定済み）。

## 本番相当構成（AWS への実デプロイ）

`terraform/` 以下に、Cognito 認証・ALB・ECS Fargate 動的タスク起動・NAT Gateway 経由のプライベートサブネット構成を Terraform 化したものを用意している。ローカル docker-compose 版とは異なり、以下を実装している。

- **Cognito Hosted UI + ALB `authenticate-cognito`** によるログイン認証（自己登録可、Pre-SignUp Lambda で許可ドメインのメールアドレスのみ登録可）。
- **ユーザーごとの動的タスク起動**: `gateway/server.js` が ALB の署名付き ID トークン（`x-amzn-oidc-data`）を検証し、ログインしたユーザーごとに専用の ECS Fargate タスクを `RunTask` で起動、WebSocket をそのタスクにプロキシする。
- **利用時間帯・セッション時間の制限**: 指定した時間帯（既定 JST 10:00–11:00）のみログインを受け付け、セッションは指定分数（既定 45 分）か時間帯終了のどちらか早い方で自動終了する。
- **利用可能モデルの制限**: IAM タスクロールで Bedrock `InvokeModel` を Claude Opus・Sonnet・Haiku の指定バージョンのみに限定（実効的な強制）。`settings.json` 側でも既定モデルとして明示。
- **ネットワーク境界**: 参加者のコンテナに直接パブリック IP は付与しない。ALB のみが外部公開され、ゲートウェイ・参加者コンテナはプライベートサブネット + NAT Gateway 経由。

### デプロイ手順

1. 前提: 既存 VPC（Internet Gateway 付き）、その VPC 内のパブリックサブネット2つ以上、対象ドメインの Route53 ホストゾーン。
2. Bedrock の利用モデルについて、AWS Marketplace の利用規約に同意する（同意前は Claude Code が `403 Model access is denied ...` で失敗し、リトライを繰り返して一見ハングしたように見える）。

   ```bash
   AWS_PROFILE=your-profile AWS_REGION=ap-northeast-1 ./scripts/accept_bedrock_agreements.sh
   ```

3. `terraform/terraform.tfvars.example` を `terraform/terraform.tfvars` にコピーして値を埋める。
   `allowed_signup_email_domains` は Cognito 自己登録を許可するメールドメイン（Pre-SignUp Lambda が
   参照）なので、必ず自分の組織の実際のドメインに書き換えること（既定のサンプル値のままでは誰も
   自己登録できない）。このファイルは `.gitignore` 対象であり、リポジトリにはコミットされない。
4. Terraform でインフラを作成する（ECR リポジトリ・ECS クラスタ・ALB・Cognito 等）。

   ```bash
   cd terraform
   terraform init
   terraform apply
   ```

5. コンテナイメージをビルドして push する。

   ```bash
   AWS_PROFILE=your-profile AWS_REGION=ap-northeast-1 ./scripts/build_and_push.sh
   ```

6. ECS サービスを新しいイメージで再デプロイする。

   ```bash
   aws ecs update-service --profile your-profile --region ap-northeast-1 \
     --cluster claude-playground-poc --service gateway --force-new-deployment
   ```

7. `terraform output playground_url` に表示される URL にアクセスし、Cognito のログイン/新規登録画面が出ることを確認する。

### 後片付け

```bash
cd terraform
terraform destroy
```

ECR リポジトリにイメージが残っていると `terraform destroy` が失敗する場合がある。その場合は先にリポジトリ内のイメージを削除してから再実行する。

### 既知の制約

- ALB 認証 + WebSocket の組み合わせは実際に検証済み（Cognito ログイン→ ALB 署名済み ID トークン検証→動的タスク起動→ WebSocket プロキシまで動作確認済み）。詳細は DESIGN.md の「要検証事項」を参照。
- Claude Code は `CLAUDE_CODE_USE_BEDROCK=1` でも `api.anthropic.com` 等の補助エンドポイント（テレメトリ・自動更新チェック等）に到達しようとする。これらの宛先向けの VPC エンドポイントは存在しないため、NAT Gateway 経由の一般的なインターネット経路を用意している（`DISABLE_AUTOUPDATER=1` 等でこれらの呼び出し自体は減らしているが完全ではない）。
- Bedrock の各モデルはリージョン/アカウントごとに AWS Marketplace 利用規約への同意が必要。同意していないモデルを呼び出すと、Claude Code はエラーメッセージを表示するまでに長いリトライを繰り返すため、原因が分かりにくい（上記デプロイ手順の 2 番目のスクリプトで解消する）。
