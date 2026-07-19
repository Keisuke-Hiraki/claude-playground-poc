variable "aws_region" {
  description = "AWS region to deploy into. Must support the Bedrock cross-region inference profiles used below."
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Leave null to use the default credential chain (env vars, instance role, etc.)."
  type        = string
  default     = null
}

variable "project_name" {
  description = "Prefix applied to the ECS cluster, IAM roles, Cognito user pool, and the Pre-SignUp Lambda."
  type        = string
  default     = "claude-playground-poc"
}

# ECR repositories and task definition families were created without the
# "-poc" suffix (e.g. "claude-playground-gateway", not
# "claude-playground-poc-gateway") — kept as a separate prefix to match.
variable "image_name_prefix" {
  description = "Prefix applied to ECR repository names and ECS task definition families."
  type        = string
  default     = "claude-playground"
}

# The ALB, its target group, and the security groups were created with a
# shorter prefix (e.g. "playground-gateway-alb", not
# "claude-playground-poc-alb") — kept as a separate prefix to match.
variable "network_resource_prefix" {
  description = "Prefix applied to the ALB, its target group, and security group names."
  type        = string
  default     = "playground"
}

variable "ecs_task_execution_role_name" {
  description = "Name of the existing ECS task execution role (image pull + log delivery) to use. This account already has the standard \"ecsTaskExecutionRole\"; point this at a project-scoped role instead if you'd rather not reuse the shared one."
  type        = string
  default     = "ecsTaskExecutionRole"
}

variable "vpc_id" {
  description = "Existing VPC to deploy into. Must already have an Internet Gateway attached (a public subnet is required for the ALB and NAT Gateway)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (route to an Internet Gateway) used for the ALB and the NAT Gateway. Provide at least 2 for the ALB across different AZs."
  type        = list(string)
}

variable "private_subnet_az" {
  description = "Availability zone for the new private subnet created for the gateway and per-user containers."
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR block for the new private subnet. Must not overlap with existing subnets in the VPC."
  type        = string
  default     = "172.31.100.0/24"
}

variable "domain_name" {
  description = "Fully-qualified domain name the playground will be served on (e.g. playground.example.com). A Route53 hosted zone for this domain (or its parent) must already exist."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that domain_name belongs to."
  type        = string
}

variable "allowed_signup_email_domains" {
  description = "Email domains allowed to self-register via Cognito (Pre-SignUp Lambda enforces this). Example: [\"example.com\", \"example.org\"]"
  type        = list(string)
}

variable "bedrock_model_ids" {
  description = "Foundation-model IDs (without the region/global prefix) the workshop is allowed to use. Must have their AWS Marketplace agreement already accepted in the account (see README) — Claude Code will otherwise fail with a Marketplace/403 error at request time, not at deploy time."
  type = object({
    opus   = string
    sonnet = string
    haiku  = string
  })
  default = {
    opus   = "claude-opus-4-6-v1"
    sonnet = "claude-sonnet-5"
    haiku  = "claude-haiku-4-5-20251001-v1:0"
  }
}

variable "bedrock_model_prefix" {
  description = "Inference-profile prefix for the Bedrock models. \"global\" spans multiple AWS regions; use a geography-scoped prefix such as \"jp\" if the models you selected have one and data residency matters."
  type        = string
  default     = "global"
}

variable "access_window_start_jst" {
  description = "Daily access window start time, JST, HH:MM. Logins are only accepted from this time until access_window_end_jst."
  type        = string
  default     = "10:00"
}

variable "access_window_end_jst" {
  description = "Daily access window end time, JST, HH:MM."
  type        = string
  default     = "11:00"
}

variable "session_max_minutes" {
  description = "Maximum minutes a single user's container may run before the gateway stops it automatically, regardless of the access window."
  type        = number
  default     = 45
}

variable "storage_limit_gib" {
  description = "Ephemeral storage size (GiB) shown in the per-user container's in-container banner (STORAGE_LIMIT_GIB env var). Informational only — the task definition does not currently set an ephemeral_storage override, so actual storage is the Fargate default (20GiB) regardless of this value."
  type        = number
  default     = 20
}

variable "user_task_cpu" {
  description = "Fargate CPU units for each per-user container (256 = .25 vCPU, 1024 = 1 vCPU, ...)."
  type        = string
  default     = "1024"
}

variable "user_task_memory" {
  description = "Fargate memory (MiB) for each per-user container."
  type        = string
  default     = "2048"
}

variable "gateway_image_tag" {
  description = "Tag to deploy for the gateway image (pushed by scripts/build_and_push.sh)."
  type        = string
  default     = "latest"
}

variable "user_image_tag" {
  description = "Tag to deploy for the per-user playground image (pushed by scripts/build_and_push.sh)."
  type        = string
  default     = "latest"
}

variable "enable_container_firewall" {
  description = "Enable the egress allowlist (init-firewall.sh) inside each per-user container, in addition to the security-group/NAT boundary. Defense in depth; see docker/init-firewall.sh for its known DNS-tunneling limitation."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the gateway and per-user containers."
  type        = number
  default     = 3
}
