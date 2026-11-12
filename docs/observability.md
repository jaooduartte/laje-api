# LAJE-40 — Observabilidade do TCC (AWS)

## Escopo e arquitetura real

Este runbook se aplica **somente** à versão acadêmica `laje-tcc` (Vercel) → API Gateway HTTP API `rkckaptyaf` → VPC Link → ALB → ECS/Fargate `laje-api` → RDS PostgreSQL 17, em `sa-east-1`. A produção operacional `laje` continua usando Supabase e **não é instrumentada** por esta alteração.

A infraestrutura é intencionalmente ligada sob demanda. Conforme [LAJE-152](https://joaoduartte.atlassian.net/browse/LAJE-152), **STOP às 00h00 está habilitado, START às 09h00 está desabilitado**. ECS `desired=0`, RDS `stopped` e falta de métricas durante uma suspensão planejada **não significam incidente**. Antes da janela acadêmica de disponibilidade contínua (até a divulgação das notas), o responsável deve suspender a política noturna e garantir funcionamento público; não alterar os agendamentos como consequência silenciosa deste PR.

## Painel CloudWatch

A definição Terraform `infra/aws/terraform/observability.tf` provisiona o painel `laje-staging-observability` e o log group `/laje/staging/apigateway-access` com retenção de 7 dias, quando a infraestrutura de API estiver habilitada. São utilizados dados de:

- `AWS/ApiGateway`: `Count`, `4xx`, `5xx`, `Latency` p95 e `IntegrationLatency`.
- `AWS/ECS`: CPU e memória do serviço.
- `AWS/ApplicationELB`: targets saudáveis. O ALB não foi substituído.
- `AWS/RDS`: CPU e armazenamento livre.
- `AWS/SQS`: mensagens visíveis nas DLQs do bracket preview e da operação noturna.
- Alarmes CloudWatch já existentes (sem ativar notificações novas).

**Acesso:** AWS Console → CloudWatch → Dashboards → `laje-staging-observability` → região São Paulo (`sa-east-1`). O dashboard **só aparecerá após o apply controlado do Terraform**; um merge da PR não o cria. O dashboard pode ter cobrança mensal (inclusive com ECS/RDS desligados), e a ingestão/retenção/consulta de logs CloudWatch pode gerar custos. Confirmar preços e plano Terraform antes do apply; não executar `Deploy AWS` apenas para este ajuste porque o workflow também atualiza imagem, executa migrations e inicia Fargate.

### Interpretação de sinais

| Sinal | Interpretação |
| --- | --- |
| `5xx` API Gateway em janela ativa | Investigar falhas de integração ou backend e logs por horário |
| `4xx` | Pode conter autenticação/validação esperada; não classificar automaticamente como incidente |
| `HealthyHostCount=0` com ECS/RDS desligados | Estado planejado; não gerar alertas de indisponibilidade |
| `HealthyHostCount=0` com ECS/RDS ativos | Investigar tasks, logs e healthcheck |
| DLQ com mensagens | Revisar o processamento correspondente e as causas; não reprocessar cegamente |
| RDS `stopped` ou ECS `desired=0` fora de sessão | Suspensão intencional, não uptime contínuo |

Um dashboard de métricas passivas **não mede uptime fim a fim da aplicação pública**: para a fase de avaliação, executar healthchecks reais (incluindo `/api/v1/health/database`) e demonstrar frontend e três fluxos obrigatórios. Canários pagos e novas notificações SNS ficaram fora deste escopo inicial.

## Logs e investigação

- API ECS: CloudWatch Logs, grupo `/laje/staging/api` (retenção existente de 7 dias).
- API Gateway: `/laje/staging/apigateway-access` (7 dias, criado após Terraform apply).
- Operações: `/laje/staging/operations` e `/laje/staging/operations/state-machine`.
- PostgreSQL: `/aws/rds/instance/laje-staging-postgres/postgresql`.

O stage `$default` registra somente request ID da API Gateway, horário, método, route key, status e duração. **Não** registra IP, URL, query string, authorization, cookies, body ou resposta. Cada resposta da aplicação Express recebe um `x-request-id` UUID e, em status 5xx, o backend emite `http_request_failed` com request ID, método, template de rota, código e duração. Exceções não tratadas emitem `unhandled_exception` sem stack/message/payload para não vazar dados pessoais.

Os request IDs da API Gateway e da aplicação **são diferentes**; o identificador `x-request-id` vincula os registros de erro da API ao evento de erro do frontend, enquanto a análise de access logs usa horário, status e rota.

Exemplos de consultas no **Logs Insights** para o grupo `/laje/staging/api`:

```sql
fields @timestamp, event, requestId, method, route, status, durationMs
| filter event = "http_request_failed"
| sort @timestamp desc
| limit 30
```

```sql
fields @timestamp, event, kind, status, code, requestId
| filter event = "frontend_error"
| sort @timestamp desc
| limit 30
```

Exemplo no grupo `/laje/staging/apigateway-access`:

```sql
fields @timestamp, requestId, method, routeKey, status, responseLatencyMs
| filter status >= 500
| sort @timestamp desc
| limit 30
```

## Frontend: captura segura e limites

A versão AWS do frontend, detectada por `VITE_BACKEND_PROVIDER=aws`, registra os tipos `javascript`, `promise`, `react-render`, `api-network` e `api-http` no endpoint `POST /api/v1/observability/client-errors`. A coleta é **best-effort**: falhas na telemetria não bloqueiam usuário e não são reenviadas quando a AWS está desligada. A produção `laje`/Supabase não instala handlers nem envia eventos. Eventos aceitam somente o tipo enumerado, status 5xx e código ASCII limitado / UUID válido; rejeitam mensagens, stack traces e outros campos. A API só recebe requests com origem CORS permitida e aplica limitação de 20 eventos/min por instância (limite operacional, não barreira de autenticação contra um cliente HTTP que falsifique Origin).

Não enviar dados pessoais, tokens ou payloads de usuário. O endpoint não coleta sessão, rota ou IP em seu próprio log. O grupo de logs e métricas já possuem regras de acesso AWS; conceder acesso ao painel conforme menor privilégio.

## Teste de aceitação e rollback

1. Com AWS ligada e frontend `laje-tcc` na versão instrumentada, verificar `GET /api/v1/health`, `GET /api/v1/health/database` e o painel CloudWatch.
2. Confirmar uma requisição API bem-sucedida na métrica `Count`, sem consultar dados sensíveis.
3. Em ambiente de teste autorizado, provocar uma falha controlada de frontend ou de status 5xx **sem tocar em dados reais**; conferir `frontend_error`, `http_request_failed`, `x-request-id` e status correspondente.
4. Conferir que nenhum campo sensível foi registrado e que, em `laje`/Supabase, não ocorreu POST de telemetria.
5. Validar CI/TypeScript, cobertura, Sonar, `terraform fmt`, `terraform validate` e revisar `terraform plan` antes do apply. Não executar o workflow `suspend`: ele tem impacto maior que observabilidade.
6. Se algum componente afetar tráfego ou custos, reverter a PR e aplicar novamente Terraform com plano revisado; não apagar grupos de logs com evidências sem avaliar retenção.

O PR prepara a implantação; **não comprova sozinho** que dashboard, logs de acesso ou ingestão do frontend já estejam ativos no ambiente publicado. A homologação final da LAJE-40 depende do deployment de código e Terraform, validação operacional e registros no Jira.
