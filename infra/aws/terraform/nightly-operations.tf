data "archive_file" "staging_operations" {
  count = var.staging_api_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/../lambda/staging-operations-handler.mjs"
  output_path = "${path.module}/.terraform/staging-operations-handler.zip"
}

resource "aws_cloudwatch_log_group" "staging_operations_lambda" {
  count = var.staging_api_enabled ? 1 : 0

  name              = "/laje/staging/operations"
  retention_in_days = 7

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_cloudwatch_log_group" "staging_operations_state_machine" {
  count = var.staging_api_enabled ? 1 : 0

  name              = "/laje/staging/operations/state-machine"
  retention_in_days = 7

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_iam_role" "staging_operations_lambda" {
  count = var.staging_api_enabled ? 1 : 0

  name = "${local.name_prefix}-operations"

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
    Jira = "LAJE-152"
  }
}

resource "aws_iam_role_policy" "staging_operations_lambda" {
  count = var.staging_api_enabled ? 1 : 0

  name = "${local.name_prefix}-operations"
  role = aws_iam_role.staging_operations_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem"
        ]
        Resource = aws_dynamodb_table.rds_rotation_lock[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource = aws_ecs_service.api[0].id
      },
      {
        Effect = "Allow"
        Action = ["ecs:ListTasks"]
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
        Action   = ["rds:DescribeDBInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["rds:StartDBInstance", "rds:StopDBInstance"]
        Resource = "arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.rotation.account_id}:db:${aws_db_instance.staging.identifier}"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.staging_operations_lambda[0].arn}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "staging_operations" {
  count = var.staging_api_enabled ? 1 : 0

  function_name    = "${local.name_prefix}-operations"
  filename         = data.archive_file.staging_operations[0].output_path
  source_code_hash = data.archive_file.staging_operations[0].output_base64sha256
  role             = aws_iam_role.staging_operations_lambda[0].arn
  handler          = "staging-operations-handler.handler"
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 30

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.staging_operations_lambda[0].name
  }

  environment {
    variables = {
      LOCK_TABLE              = aws_dynamodb_table.rds_rotation_lock[0].name
      ECS_CLUSTER_NAME        = aws_ecs_cluster.api.name
      ECS_SERVICE_NAME        = aws_ecs_service.api[0].name
      RDS_INSTANCE_IDENTIFIER = aws_db_instance.staging.identifier
      API_ENDPOINT            = aws_apigatewayv2_api.api[0].api_endpoint
    }
  }

  depends_on = [
    aws_iam_role_policy.staging_operations_lambda,
    aws_cloudwatch_log_group.staging_operations_lambda
  ]

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_iam_role" "staging_operations_state_machine" {
  count = var.staging_api_enabled ? 1 : 0

  name = "${local.name_prefix}-operations-sfn"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "states.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_iam_role_policy" "staging_operations_state_machine" {
  count = var.staging_api_enabled ? 1 : 0

  name = "${local.name_prefix}-operations-sfn"
  role = aws_iam_role.staging_operations_state_machine[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.staging_operations[0].arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:DescribeLogGroups",
          "logs:DescribeResourcePolicies",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:UpdateLogDelivery"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "staging_operations" {
  count = var.staging_api_enabled ? 1 : 0

  name     = "${local.name_prefix}-operations"
  role_arn = aws_iam_role.staging_operations_state_machine[0].arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/staging-operations.asl.json", {
    staging_operations_lambda_arn = aws_lambda_function.staging_operations[0].arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.staging_operations_state_machine[0].arn}:*"
    include_execution_data = false
    level                  = "ALL"
  }

  depends_on = [aws_iam_role_policy.staging_operations_state_machine]

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_sns_topic" "staging_operations" {
  count = var.staging_api_enabled ? 1 : 0

  name = "${local.name_prefix}-operations-alerts"

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_sns_topic_subscription" "staging_operations_email" {
  count = var.staging_api_enabled && length(trimspace(var.staging_automation_alert_email)) > 0 ? 1 : 0

  topic_arn = aws_sns_topic.staging_operations[0].arn
  protocol  = "email"
  endpoint  = var.staging_automation_alert_email
}

resource "aws_sqs_queue" "staging_operations_dlq" {
  count = var.staging_api_enabled ? 1 : 0

  name                      = "${local.name_prefix}-operations-dlq"
  message_retention_seconds = 604800
  sqs_managed_sse_enabled   = true

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_iam_role" "staging_operations_scheduler" {
  count = var.staging_api_enabled ? 1 : 0

  name = "${local.name_prefix}-operations-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.rotation.account_id
        }
      }
    }]
  })

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_iam_role_policy" "staging_operations_scheduler" {
  count = var.staging_api_enabled ? 1 : 0

  name = "${local.name_prefix}-operations-scheduler"
  role = aws_iam_role.staging_operations_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = aws_sfn_state_machine.staging_operations[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.staging_operations_dlq[0].arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "staging_operations_stop" {
  count = var.staging_api_enabled ? 1 : 0

  name                         = "${local.name_prefix}-operations-stop"
  schedule_expression          = "cron(0 0 * * ? *)"
  schedule_expression_timezone = "America/Sao_Paulo"
  state                        = var.staging_automation_schedules_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.staging_operations[0].arn
    role_arn = aws_iam_role.staging_operations_scheduler[0].arn
    input    = jsonencode({ action = "stop" })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }

    dead_letter_config {
      arn = aws_sqs_queue.staging_operations_dlq[0].arn
    }
  }

  depends_on = [aws_iam_role_policy.staging_operations_scheduler]
}

resource "aws_scheduler_schedule" "staging_operations_start" {
  count = var.staging_api_enabled ? 1 : 0

  name                         = "${local.name_prefix}-operations-start"
  schedule_expression          = "cron(0 9 * * ? *)"
  schedule_expression_timezone = "America/Sao_Paulo"
  state                        = var.staging_automation_schedules_enabled && var.staging_automation_auto_start_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.staging_operations[0].arn
    role_arn = aws_iam_role.staging_operations_scheduler[0].arn
    input    = jsonencode({ action = "start" })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }

    dead_letter_config {
      arn = aws_sqs_queue.staging_operations_dlq[0].arn
    }
  }

  depends_on = [aws_iam_role_policy.staging_operations_scheduler]
}

resource "aws_cloudwatch_event_rule" "staging_operations_failures" {
  count = var.staging_api_enabled ? 1 : 0

  name        = "${local.name_prefix}-operations-failures"
  description = "LAJE-152 staging lifecycle executions that failed or exceeded their timeout."

  event_pattern = jsonencode({
    source        = ["aws.states"]
    "detail-type" = ["Step Functions Execution Status Change"]
    detail = {
      status          = ["FAILED", "TIMED_OUT", "ABORTED"]
      stateMachineArn = [aws_sfn_state_machine.staging_operations[0].arn]
    }
  })

  tags = {
    Jira = "LAJE-152"
  }
}

resource "aws_cloudwatch_event_target" "staging_operations_failures" {
  count = var.staging_api_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.staging_operations_failures[0].name
  target_id = "staging-operations-email"
  arn       = aws_sns_topic.staging_operations[0].arn

  depends_on = [aws_sns_topic_policy.staging_operations]
}

resource "aws_sns_topic_policy" "staging_operations" {
  count = var.staging_api_enabled ? 1 : 0

  arn = aws_sns_topic.staging_operations[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowLifecycleFailureNotifications"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.staging_operations[0].arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.staging_operations_failures[0].arn
        }
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.rotation.account_id
        }
      }
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "staging_operations_dlq" {
  count = var.staging_api_enabled ? 1 : 0

  alarm_name          = "${local.name_prefix}-operations-dlq-not-empty"
  alarm_description   = "LAJE-152 scheduler invocations could not start the lifecycle state machine."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.staging_operations_dlq[0].name
  }

  alarm_actions = [aws_sns_topic.staging_operations[0].arn]

  tags = {
    Jira = "LAJE-152"
  }
}
