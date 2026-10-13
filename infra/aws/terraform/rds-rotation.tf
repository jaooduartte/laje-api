# LAJE-143: refresh ECS tasks when the RDS-managed Secrets Manager AWSCURRENT label moves.
# This is isolated to staging; no Supabase or production resources are referenced.
data "aws_caller_identity" "rotation" {}

data "archive_file" "rds_rotation" {
  count       = var.staging_api_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/../lambda/rds-rotation-handler.mjs"
  output_path = "${path.module}/.terraform/laje-rds-rotation-handler.zip"
}

resource "aws_cloudwatch_log_group" "rds_rotation" {
  count             = var.staging_api_enabled ? 1 : 0
  name              = "/laje/staging/rds-rotation"
  retention_in_days = 7

  tags = {
    Jira = "LAJE-143"
  }
}

resource "aws_iam_role" "rds_rotation" {
  count = var.staging_api_enabled ? 1 : 0
  name  = "${local.name_prefix}-rds-rotation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Jira = "LAJE-143"
  }
}


resource "aws_dynamodb_table" "rds_rotation_lock" {
  count        = var.staging_api_enabled ? 1 : 0
  name         = "${local.name_prefix}-rds-rotation-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockId"

  attribute {
    name = "LockId"
    type = "S"
  }

  ttl {
    attribute_name = "ExpiresAt"
    enabled        = true
  }

  tags = {
    Jira = "LAJE-143"
  }
}

resource "aws_iam_role_policy" "rds_rotation" {
  count = var.staging_api_enabled ? 1 : 0
  name  = "${local.name_prefix}-rds-rotation"
  role  = aws_iam_role.rds_rotation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.rds_rotation_lock[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret"]
        Resource = aws_db_instance.staging.master_user_secret[0].secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource = aws_ecs_service.api[0].id
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:ListTasks"]
        Resource = [
          aws_ecs_cluster.api.arn,
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.rotation.account_id}:container-instance/${aws_ecs_cluster.api.name}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.rotation.account_id}:task/${aws_ecs_cluster.api.name}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.rds_rotation[0].arn}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "rds_rotation" {
  count = var.staging_api_enabled ? 1 : 0

  function_name    = "${local.name_prefix}-rds-rotation"
  filename         = data.archive_file.rds_rotation[0].output_path
  source_code_hash = data.archive_file.rds_rotation[0].output_base64sha256
  role             = aws_iam_role.rds_rotation[0].arn
  handler          = "rds-rotation-handler.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 600

  # Match the pre-created log group and the role's scoped PutLogEvents policy.
  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.rds_rotation[0].name
  }

  environment {
    variables = {
      EXPECTED_AWS_ACCOUNT = data.aws_caller_identity.rotation.account_id
      EXPECTED_AWS_REGION  = var.aws_region
      RDS_SECRET_ARN       = aws_db_instance.staging.master_user_secret[0].secret_arn
      ROTATION_LOCK_TABLE  = aws_dynamodb_table.rds_rotation_lock[0].name
      ECS_CLUSTER_NAME     = aws_ecs_cluster.api.name
      ECS_SERVICE_NAME     = aws_ecs_service.api[0].name
      DATABASE_HEALTH_URL  = "${aws_apigatewayv2_api.api[0].api_endpoint}/api/v1/health/database"
      PUBLIC_SETTINGS_URL  = "${aws_apigatewayv2_api.api[0].api_endpoint}/api/v1/public/settings"
    }
  }

  depends_on = [
    aws_iam_role_policy.rds_rotation,
    aws_cloudwatch_log_group.rds_rotation
  ]

  tags = {
    Jira = "LAJE-143"
  }
}

# Secrets Manager emits this event natively (without requiring CloudTrail).
resource "aws_cloudwatch_event_rule" "rds_rotation" {
  count       = var.staging_api_enabled ? 1 : 0
  name        = "${local.name_prefix}-rds-rotation"
  description = "LAJE-143: updated AWSCURRENT version of the exact staging RDS master secret."

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["Secret Label Updated"]
    account       = [data.aws_caller_identity.rotation.account_id]
    region        = [var.aws_region]
    resources     = [aws_db_instance.staging.master_user_secret[0].secret_arn]
    detail = {
      labelUpdated = ["AWSCURRENT"]
    }
  })

  tags = {
    Jira = "LAJE-143"
  }
}

resource "aws_cloudwatch_event_target" "rds_rotation" {
  count = var.staging_api_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.rds_rotation[0].name
  arn   = aws_lambda_function.rds_rotation[0].arn
}

resource "aws_lambda_permission" "rds_rotation" {
  count         = var.staging_api_enabled ? 1 : 0
  statement_id  = "AllowStagingRdsRotationEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_rotation[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rds_rotation[0].arn
}

resource "aws_cloudwatch_metric_alarm" "rds_rotation_errors" {
  count               = var.staging_api_enabled ? 1 : 0
  alarm_name          = "${local.name_prefix}-rds-rotation-errors"
  alarm_description   = "LAJE-143: RDS rotation Lambda handler failed; ECS may still use old credentials."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.rds_rotation[0].function_name
  }

  tags = {
    Jira = "LAJE-143"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_rotation_delivery" {
  count               = var.staging_api_enabled ? 1 : 0
  alarm_name          = "${local.name_prefix}-rds-rotation-delivery-failed"
  alarm_description   = "LAJE-143: EventBridge failed to invoke the rotation Lambda."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  metric_name         = "FailedInvocations"
  namespace           = "AWS/Events"
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleName = aws_cloudwatch_event_rule.rds_rotation[0].name
  }

  tags = {
    Jira = "LAJE-143"
  }
}
