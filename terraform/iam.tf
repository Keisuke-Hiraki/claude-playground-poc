data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ECS task execution role (image pull + log delivery). Uses the account's
# standard "ecsTaskExecutionRole" rather than a project-scoped one — this
# account already had it from prior work, so both task definitions point at
# it via var.ecs_task_execution_role_name.
data "aws_iam_role" "ecs_task_execution" {
  name = var.ecs_task_execution_role_name
}

# --- Per-user container task role -----------------------------------------
# This is the single most important IAM boundary in the whole design: a
# workshop participant has a shell in this container, so the task role IS
# the participant's effective permission set. It must never carry anything
# beyond InvokeModel on the three approved models.
resource "aws_iam_role" "user_task" {
  name               = "${var.project_name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

locals {
  approved_model_ids = [
    var.bedrock_model_ids.opus,
    var.bedrock_model_ids.sonnet,
    var.bedrock_model_ids.haiku,
  ]
}

data "aws_iam_policy_document" "bedrock_invoke_approved_models" {
  statement {
    sid    = "InvokeApprovedModelsOnly"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = concat(
      [for id in local.approved_model_ids : "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_prefix}.anthropic.${id}"],
      [for id in local.approved_model_ids : "arn:aws:bedrock:*::foundation-model/anthropic.${id}"],
    )
  }
}

resource "aws_iam_role_policy" "user_task_bedrock" {
  name   = "bedrock-invoke-approved-models"
  role   = aws_iam_role.user_task.id
  policy = data.aws_iam_policy_document.bedrock_invoke_approved_models.json
}

# --- Gateway task role -------------------------------------------------
# The gateway needs to launch/stop/describe tasks in this cluster and pass
# the two roles above to them — nothing broader.
resource "aws_iam_role" "gateway_task" {
  name               = "${var.project_name}-gateway-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

data "aws_iam_policy_document" "gateway_manage_user_tasks" {
  statement {
    sid    = "ManagePlaygroundUserTasks"
    effect = "Allow"
    actions = [
      "ecs:RunTask",
      "ecs:StopTask",
      "ecs:DescribeTasks",
    ]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }

  statement {
    sid       = "PassRolesToLaunchedTasks"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [data.aws_iam_role.ecs_task_execution.arn, aws_iam_role.user_task.arn]
  }

  statement {
    sid       = "ResolveTaskPrivateIp"
    effect    = "Allow"
    actions   = ["ec2:DescribeNetworkInterfaces"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gateway_task" {
  name   = "manage-playground-user-tasks"
  role   = aws_iam_role.gateway_task.id
  policy = data.aws_iam_policy_document.gateway_manage_user_tasks.json
}
