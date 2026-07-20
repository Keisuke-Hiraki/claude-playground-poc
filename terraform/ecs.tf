resource "aws_ecs_cluster" "this" {
  name = var.project_name
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecr_repository" "gateway" {
  name                 = "${var.image_name_prefix}-gateway"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "user" {
  name                 = "${var.image_name_prefix}-user"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- Per-user playground task definition ----------------------------------
# Launched dynamically by the gateway (ecs:RunTask) — never run as a
# standalone service. See gateway/server.js launchSession().
resource "aws_ecs_task_definition" "user" {
  family                   = "${var.image_name_prefix}-user"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.user_task_cpu
  memory                   = var.user_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.user_task.arn

  container_definitions = jsonencode([
    {
      name         = "claude-user"
      image        = "${aws_ecr_repository.user.repository_url}:${var.user_image_tag}"
      essential    = true
      portMappings = [{ containerPort = 7681, protocol = "tcp" }]
      environment = [
        { name = "CLAUDE_CODE_USE_BEDROCK", value = "1" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ANTHROPIC_MODEL", value = "${var.bedrock_model_prefix}.anthropic.${var.bedrock_model_ids.sonnet}" },
        { name = "ANTHROPIC_DEFAULT_OPUS_MODEL", value = "${var.bedrock_model_prefix}.anthropic.${var.bedrock_model_ids.opus}" },
        { name = "ANTHROPIC_DEFAULT_SONNET_MODEL", value = "${var.bedrock_model_prefix}.anthropic.${var.bedrock_model_ids.sonnet}" },
        { name = "ANTHROPIC_DEFAULT_HAIKU_MODEL", value = "${var.bedrock_model_prefix}.anthropic.${var.bedrock_model_ids.haiku}" },
        { name = "ANTHROPIC_SMALL_FAST_MODEL", value = "${var.bedrock_model_prefix}.anthropic.${var.bedrock_model_ids.haiku}" },
        { name = "ENABLE_FIREWALL", value = tostring(var.enable_container_firewall) },
        { name = "DISABLE_AUTOUPDATER", value = "1" },
        { name = "DISABLE_TELEMETRY", value = "1" },
        { name = "DISABLE_ERROR_REPORTING", value = "1" },
        { name = "WINDOW_START_JST", value = var.access_window_start_jst },
        { name = "WINDOW_END_JST", value = var.access_window_end_jst },
        { name = "SESSION_MAX_MINUTES", value = tostring(var.session_max_minutes) },
        { name = "STORAGE_LIMIT_GIB", value = tostring(var.storage_limit_gib) },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "user"
        }
      }
    }
  ])

  # Not set: the deployed task definition doesn't override ephemeral storage
  # (leaves it at the Fargate default of 20GiB). var.storage_limit_gib still
  # drives the in-container banner text; keep the two in sync manually if you
  # add an override here.
}

# --- Gateway service --------------------------------------------------
resource "aws_ecs_task_definition" "gateway" {
  family                   = "${var.image_name_prefix}-gateway"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.gateway_task.arn

  container_definitions = jsonencode([
    {
      name         = "gateway"
      image        = "${aws_ecr_repository.gateway.repository_url}:${var.gateway_image_tag}"
      essential    = true
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]
      environment = [
        { name = "PORT", value = "8080" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ECS_CLUSTER", value = aws_ecs_cluster.this.name },
        { name = "TASK_DEFINITION", value = aws_ecs_task_definition.user.family },
        { name = "CONTAINER_NAME", value = "claude-user" },
        { name = "SUBNET_IDS", value = aws_subnet.private.id },
        { name = "CONTAINER_SECURITY_GROUPS", value = aws_security_group.container.id },
        { name = "SESSION_MAX_MINUTES", value = tostring(var.session_max_minutes) },
        { name = "WINDOW_START_JST", value = var.access_window_start_jst },
        { name = "WINDOW_END_JST", value = var.access_window_end_jst },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "gateway"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "gateway" {
  name            = "gateway"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private.id]
    security_groups  = [aws_security_group.gateway.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "gateway"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.https]
}
