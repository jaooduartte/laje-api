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

resource "aws_iam_role_policy" "ecs_execution_rds_secret" {
  name = "${local.name_prefix}-rds-secret"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_db_instance.staging.master_user_secret[0].secret_arn
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
        { name = "AUTH_ENABLED", value = "false" },
        { name = "AWS_ENABLED", value = "false" },
        { name = "MAIL_ENABLED", value = "false" }
      ]

      secrets = [
        {
          name      = "DATABASE_USER"
          valueFrom = "${aws_db_instance.staging.master_user_secret[0].secret_arn}:username::"
        },
        {
          name      = "DATABASE_PASSWORD"
          valueFrom = "${aws_db_instance.staging.master_user_secret[0].secret_arn}:password::"
        }
      ]

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
    aws_iam_role_policy.ecs_execution_rds_secret
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
