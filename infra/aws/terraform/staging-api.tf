data "aws_secretsmanager_secret" "auth_jwt" {
  name = var.staging_auth_jwt_secret_name
}


resource "aws_sqs_queue" "bracket_preview_dlq" {
  name                      = "${local.name_prefix}-bracket-preview-dlq"
  message_retention_seconds = var.bracket_preview_dlq_retention_seconds

  tags = {
    Jira = "LAJE-126"
  }
}

resource "aws_sqs_queue" "bracket_preview" {
  name                       = "${local.name_prefix}-bracket-preview"
  visibility_timeout_seconds = var.bracket_preview_visibility_timeout_seconds
  message_retention_seconds  = var.bracket_preview_message_retention_seconds
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.bracket_preview_dlq.arn
    maxReceiveCount     = var.bracket_preview_max_receive_count
  })

  tags = {
    Jira = "LAJE-126"
  }
}

resource "aws_cloudwatch_metric_alarm" "bracket_preview_dlq" {
  alarm_name          = "${local.name_prefix}-bracket-preview-dlq-not-empty"
  alarm_description   = "LAJE-126: messages reached the bracket preview DLQ."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.bracket_preview_dlq.name
  }

  tags = {
    Jira = "LAJE-126"
  }
}

resource "aws_cloudwatch_metric_alarm" "bracket_preview_age" {
  alarm_name          = "${local.name_prefix}-bracket-preview-oldest-message"
  alarm_description   = "LAJE-126: preview queue contains a message older than five minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 300
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.bracket_preview.name
  }

  tags = {
    Jira = "LAJE-126"
  }
}

resource "aws_iam_role" "bracket_preview_scheduler" {
  name = "${local.name_prefix}-bracket-preview-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Jira = "LAJE-126"
  }
}

resource "aws_iam_role_policy" "bracket_preview_scheduler" {
  name = "${local.name_prefix}-bracket-preview-scheduler"
  role = aws_iam_role.bracket_preview_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.bracket_preview.arn
    }]
  })
}

resource "aws_scheduler_schedule" "bracket_preview_maintenance" {
  name                = "${local.name_prefix}-bracket-preview-maintenance"
  schedule_expression = var.bracket_preview_maintenance_schedule
  state               = var.staging_api_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.bracket_preview.arn
    role_arn = aws_iam_role.bracket_preview_scheduler.arn
    input    = jsonencode({ type = "MAINTENANCE" })
  }
}

resource "aws_ecr_repository" "api" {
  name                 = "${local.name_prefix}-api"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${local.name_prefix}-api"
    Jira = "LAJE-136"
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the three newest staging images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 3
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/laje/staging/api"
  retention_in_days = var.staging_api_log_retention_days

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_ecs_cluster" "api" {
  name = "${local.name_prefix}-api"

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_iam_role" "ecs_execution" {
  name = "${local.name_prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Jira = "LAJE-126"
  }
}

resource "aws_iam_role_policy" "ecs_task_bracket_preview" {
  name = "${local.name_prefix}-bracket-preview"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes"
      ]
      Resource = aws_sqs_queue.bracket_preview.arn
    }]
  })
}

resource "aws_iam_role_policy" "ecs_execution_rds_secret" {
  name = "${local.name_prefix}-rds-secret"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = concat(
          [
            aws_db_instance.staging.master_user_secret[0].secret_arn,
            data.aws_secretsmanager_secret.auth_jwt.arn
          ],
          var.staging_mail_enabled ? [var.staging_brevo_api_key_secret_arn] : []
        )
      }
    ]
  })
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${aws_ecr_repository.api.repository_url}:${var.staging_api_image_tag}"
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = var.app_port
          hostPort      = var.app_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "PORT", value = tostring(var.app_port) },
        { name = "DATABASE_HOST", value = aws_db_instance.staging.address },
        { name = "DATABASE_PORT", value = tostring(aws_db_instance.staging.port) },
        { name = "DATABASE_NAME", value = aws_db_instance.staging.db_name },
        { name = "DATABASE_SSLMODE", value = "require" },
        { name = "DATABASE_POOL_MAX", value = "5" },
        { name = "CORS_ORIGINS", value = var.staging_api_cors_origins },
        { name = "AUTH_ENABLED", value = "true" },
        { name = "AUTH_JWT_EXPIRES_IN", value = "15m" },
        { name = "AUTH_REFRESH_EXPIRES_IN_DAYS", value = "30" },
        { name = "AWS_ENABLED", value = "true" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "BRACKET_PREVIEW_QUEUE_URL", value = aws_sqs_queue.bracket_preview.url },
        { name = "BRACKET_PREVIEW_WORKER_ENABLED", value = "true" },
        { name = "BRACKET_PREVIEW_POLL_WAIT_SECONDS", value = "20" },
        { name = "BRACKET_PREVIEW_VISIBILITY_TIMEOUT_SECONDS", value = tostring(var.bracket_preview_visibility_timeout_seconds) },
        { name = "BRACKET_PREVIEW_MAX_RECEIVE_COUNT", value = tostring(var.bracket_preview_max_receive_count) },
        { name = "MAIL_ENABLED", value = tostring(var.staging_mail_enabled) },
        { name = "MAIL_FROM", value = var.staging_mail_from },
        { name = "MAIL_FROM_NAME", value = var.staging_mail_from_name },
        { name = "CO_EVENTS_EMAIL", value = var.staging_co_events_email },
        { name = "CO_PRESIDENCY_EMAIL", value = var.staging_co_presidency_email },
        { name = "APP_URL", value = var.staging_app_url }
      ]

      secrets = concat(
        [
          {
            name      = "DATABASE_USER"
            valueFrom = "${aws_db_instance.staging.master_user_secret[0].secret_arn}:username::"
          },
          {
            name      = "DATABASE_PASSWORD"
            valueFrom = "${aws_db_instance.staging.master_user_secret[0].secret_arn}:password::"
          },
          {
            name      = "AUTH_JWT_SECRET"
            valueFrom = data.aws_secretsmanager_secret.auth_jwt.arn
          }
        ],
        var.staging_mail_enabled ? [
          {
            name      = "BREVO_API_KEY"
            valueFrom = var.staging_brevo_api_key_secret_arn
          }
        ] : []
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "api"
        }
      }

      healthCheck = {
        command = [
          "CMD-SHELL",
          "node -e \"fetch('http://127.0.0.1:' + (process.env.PORT || '3000') + '/api/v1/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))\""
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }
    }
  ])

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_lb" "api" {
  count = var.staging_api_enabled ? 1 : 0

  name                       = "${local.name_prefix}-api"
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.app_private[*].id
  enable_deletion_protection = false
  drop_invalid_header_fields = true
  idle_timeout               = 30

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_lb_target_group" "api" {
  count = var.staging_api_enabled ? 1 : 0

  name                 = "${local.name_prefix}-api"
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 10

  health_check {
    enabled             = true
    path                = "/api/v1/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 20
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_lb_listener" "api_http" {
  count = var.staging_api_enabled ? 1 : 0

  load_balancer_arn = aws_lb.api[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[0].arn
  }
}

resource "aws_ecs_service" "api" {
  count = var.staging_api_enabled ? 1 : 0

  name            = "${local.name_prefix}-api"
  cluster         = aws_ecs_cluster.api.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.staging_api_desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  health_check_grace_period_seconds  = 60

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api[0].arn
    container_name   = "api"
    container_port   = var.app_port
  }

  depends_on = [
    aws_lb_listener.api_http,
    aws_iam_role_policy_attachment.ecs_execution,
    aws_iam_role_policy.ecs_execution_rds_secret,
    aws_iam_role_policy.ecs_task_bracket_preview
  ]

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_apigatewayv2_vpc_link" "api" {
  count = var.staging_api_enabled ? 1 : 0

  name               = "${local.name_prefix}-api"
  security_group_ids = [aws_security_group.alb.id]
  subnet_ids         = aws_subnet.app_private[*].id

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_apigatewayv2_api" "api" {
  count = var.staging_api_enabled ? 1 : 0

  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_credentials = true
    allow_headers     = ["authorization", "content-type", "x-request-id"]
    allow_methods     = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    allow_origins     = [for origin in split(",", var.staging_api_cors_origins) : trimspace(origin)]
    expose_headers    = ["x-request-id"]
    max_age           = 300
  }

  tags = {
    Jira = "LAJE-136"
  }
}

resource "aws_apigatewayv2_integration" "api" {
  count = var.staging_api_enabled ? 1 : 0

  api_id                 = aws_apigatewayv2_api.api[0].id
  integration_type       = "HTTP_PROXY"
  integration_uri        = aws_lb_listener.api_http[0].arn
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.api[0].id
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "api_default" {
  count = var.staging_api_enabled ? 1 : 0

  api_id    = aws_apigatewayv2_api.api[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.api[0].id}"
}

resource "aws_apigatewayv2_stage" "api_default" {
  count = var.staging_api_enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.api[0].id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = false
    throttling_burst_limit   = 100
    throttling_rate_limit    = 50
  }

  tags = {
    Jira = "LAJE-136"
  }
}
