# Claude Code 勉強会プレイグラウンド — PoC

Cognito でユーザー管理し、コンテナ上で動く Claude Code に PTY 経由でブラウザからアクセスする「共通プレイグラウンド」の実現可能性検証 PoC。

設計の背景・アーキテクチャ解説・セキュリティ設計・ハマりポイント等は別途ブログ記事で解説する（リンクは追記予定）。

## 構成

```
docker/              Claude Code + ttyd のコンテナイメージ（参加者用）
gateway/             セッションゲートウェイ（ユーザー→コンテナのWebSocketプロキシ）
docker-compose.yml   ローカル確認用: alice/bob 用コンテナ2台 + gateway
terraform/           AWS 本番相当構成一式（Cognito, ALB, ECS Fargate, NAT Gateway 等）
lambda/pre-signup/   Cognito 自己登録の許可メールドメイン制限（Pre-SignUp トリガー）
scripts/             Bedrock モデルの Marketplace 同意、イメージビルド&push
```

## ローカル（docker-compose）

構築:

```bash
cp .env.example .env
# .env に AWS_ACCESS_KEY_ID 等を記入（無くてもビルド・ルーティング確認は可能）

docker compose up --build
```

`http://localhost:8080/login?user=alice` / `?user=bob`（別ブラウザ or シークレットウィンドウ）で、ユーザーごとに別コンテナへ振り分けられることを確認する。端末が開いたら `claude --version` や `claude` で起動確認する。

削除:

```bash
docker compose down
```

## AWS（Terraform、本番相当構成）

構築:

1. 前提: 既存 VPC（Internet Gateway 付き）、その VPC 内のパブリックサブネット2つ以上、対象ドメインの Route53 ホストゾーン。
2. Bedrock の利用モデルについて、AWS Marketplace の利用規約に同意する。

   ```bash
   AWS_PROFILE=your-profile AWS_REGION=ap-northeast-1 ./scripts/accept_bedrock_agreements.sh
   ```

3. `terraform/terraform.tfvars.example` を `terraform/terraform.tfvars` にコピーして値を埋める（変数の説明は [`terraform/variables.tf`](./terraform/variables.tf) を参照）。このファイルは `.gitignore` 対象。
4. Terraform でインフラを作成する。

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

削除:

```bash
cd terraform
terraform destroy
```

ECR にイメージが残っている場合や、参加者が動的起動したコンテナ（ECS Fargate タスク）が稼働中の場合は `terraform destroy` が失敗することがある。その場合は先にイメージ削除・タスク停止（`aws ecs list-tasks` / `aws ecs stop-task`）を行ってから再実行する。
