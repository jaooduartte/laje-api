# LAJE-40: minimum, low-cost observability for the published TCC environment.
# Access logs deliberately omit URL, query string, IP, cookies, headers and payloads.
resource "aws_cloudwatch_log_group" "api_gateway_access" {
  count = var.staging_api_enabled ? 1 : 0

  name              = "/laje/staging/apigateway-access"
  retention_in_days = 7

  tags = {
    Jira = "LAJE-40"
  }
}

resource "aws_cloudwatch_dashboard" "staging_observability" {
  count = var.staging_api_enabled ? 1 : 0

  dashboard_name = "${local.name_prefix}-observability"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          markdown = "## LAJE TCC — observabilidade\n**Operação sob demanda:** ECS/RDS desligados são esperados fora das sessões de uso (LAJE-152). Ausência de métricas durante a suspensão não é incidente. Durante a janela acadêmica de disponibilidade pública, manter os recursos ligados e revisar os alertas."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway — requisições e falhas HTTP"
          region = var.aws_region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.api[0].id, "Stage", "$default", { stat = "Sum", label = "Requisições" }],
            ["AWS/ApiGateway", "4xx", "ApiId", aws_apigatewayv2_api.api[0].id, "Stage", "$default", { stat = "Sum", label = "4xx (inclui respostas esperadas)" }],
            ["AWS/ApiGateway", "5xx", "ApiId", aws_apigatewayv2_api.api[0].id, "Stage", "$default", { stat = "Sum", label = "5xx" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway — latência (ms)"
          region = var.aws_region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", aws_apigatewayv2_api.api[0].id, "Stage", "$default", { stat = "p95", label = "Latência p95" }],
            ["AWS/ApiGateway", "IntegrationLatency", "ApiId", aws_apigatewayv2_api.api[0].id, "Stage", "$default", { stat = "Average", label = "Integração (média)" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "ECS/Fargate — CPU e memória (%)"
          region = var.aws_region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.api.name, "ServiceName", aws_ecs_service.api[0].name, { stat = "Average", label = "CPU" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.api.name, "ServiceName", aws_ecs_service.api[0].name, { stat = "Average", label = "Memória" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "ALB — targets saudáveis"
          region = var.aws_region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.api[0].arn_suffix, "LoadBalancer", aws_lb.api[0].arn_suffix, { stat = "Average", label = "Targets saudáveis" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 15
        width  = 12
        height = 6
        properties = {
          title  = "RDS — CPU (%)"
          region = var.aws_region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.staging.identifier, { stat = "Average" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 15
        width  = 12
        height = 6
        properties = {
          title  = "RDS — espaço livre (bytes)"
          region = var.aws_region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", aws_db_instance.staging.identifier, { stat = "Minimum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 21
        width  = 12
        height = 6
        properties = {
          title  = "SQS — mensagens em DLQ"
          region = var.aws_region
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.bracket_preview_dlq.name, { stat = "Maximum", label = "Preview de chaveamento" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.staging_operations_dlq[0].name, { stat = "Maximum", label = "Operações ECS/RDS" }]
          ]
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 21
        width  = 12
        height = 6
        properties = {
          title = "Alarmes já existentes (sem ampliar notificações)"
          alarms = [
            aws_cloudwatch_metric_alarm.bracket_preview_dlq.arn,
            aws_cloudwatch_metric_alarm.bracket_preview_age.arn,
            aws_cloudwatch_metric_alarm.staging_rds_high_cpu.arn,
            aws_cloudwatch_metric_alarm.staging_rds_low_free_storage.arn,
            aws_cloudwatch_metric_alarm.staging_operations_dlq[0].arn
          ]
        }
      }
    ]
  })
}
