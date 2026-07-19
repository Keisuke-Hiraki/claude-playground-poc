output "playground_url" {
  description = "URL participants use to access the playground."
  value       = "https://${var.domain_name}/login"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_hosted_ui_domain" {
  value = aws_cognito_user_pool_domain.this.domain
}

output "ecr_gateway_repository_url" {
  value = aws_ecr_repository.gateway.repository_url
}

output "ecr_user_repository_url" {
  value = aws_ecr_repository.user.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "alb_dns_name" {
  value = aws_lb.gateway.dns_name
}

output "bedrock_marketplace_agreement_reminder" {
  description = "Reminder: this account must have accepted the AWS Marketplace agreement for each approved model, or Claude Code will fail at request time with a 403 (not caught by this Terraform run). See README.md § Bedrock model access."
  value = join(", ", [
    "anthropic.${var.bedrock_model_ids.opus}",
    "anthropic.${var.bedrock_model_ids.sonnet}",
    "anthropic.${var.bedrock_model_ids.haiku}",
  ])
}
