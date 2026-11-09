# Workloads operacionais AWS — LAJE-126

## Escopo atual para a entrega TCC

Esta documentação descreve os workloads AWS da versão web `laje-tcc`, executados pela `laje-api`. O runtime atual usa o RDS `laje-staging-postgres`, que é o único banco AWS selecionado para a entrega. O prefixo `staging` em nomes de recursos registra a nomenclatura existente; não representa um segundo ambiente de banco necessário à publicação.

Os detalhes de fila, scheduler, e-mail e calendário abaixo preservam decisões técnicas e evidências históricas da LAJE-126. A validação temporária realizada em 07/10/2026 não deve ser confundida com o estado atual do deployment; consulte o workflow e os health checks da versão que será apresentada.

## Objetivo

Remover do estado-alvo do LAJE as dependências operacionais de `pgmq`, `pg_cron`, Supabase Vault e Edge Functions, mantendo o frontend em Vercel pela exceção específica já aprovada para o projeto e transferindo backend, banco, filas, agendamentos, segredos e observabilidade para a arquitetura controlada na AWS.

## Inventário de origem

O ambiente Supabase legado possui:

| Origem                                               | Uso legado                       | Alvo AWS                             |
| ---------------------------------------------------- | -------------------------------- | ------------------------------------ |
| `pgmq` / fila `championship_bracket_preview`         | Prévia assíncrona de chaveamento | Amazon SQS + DLQ                     |
| `pg_cron` a cada 2 minutos                           | Recovery/cleanup de previews     | Amazon EventBridge Scheduler         |
| Edge Function `process-championship-bracket-preview` | Consumidor HTTP da fila/RPC      | Worker Node dentro da `laje-api`     |
| Edge Function `send-reservation-email`               | E-mails Brevo de reserva         | Serviço de notificação da `laje-api` |
| Edge Function `calendar-subscription-feed`           | Feed iCalendar público           | Endpoint PostgreSQL da `laje-api`    |
| Supabase service role / segredos de função           | Acesso privilegiado              | IAM + AWS Secrets Manager            |
| Logs da Edge Function                                | Diagnóstico                      | CloudWatch Logs/Metrics/Alarms       |

O inventário registra a origem técnica da portabilidade dos workloads. A publicação documentada para o TCC usa os contratos AWS da `laje-api`.

## Prévia assíncrona de chaveamento

### Fluxo

```text
Frontend AWS-only
  -> POST laje-api preview-jobs
  -> PostgreSQL/RDS: championship_bracket_preview_private.*
  -> Amazon SQS
  -> worker Node na task ECS/Fargate
  -> motor exato v8 no PostgreSQL/RDS, orquestrado pela laje-api
  -> frontend consulta status/dia pela laje-api
  -> criação aprovada também passa pela laje-api
```

A fila principal possui DLQ e política de redrive. A entrega é tratada como at-least-once. Cada mensagem executa um passo retomável do motor v8; quando o próprio motor indica `continue=true`, a `laje-api` publica exatamente a continuação solicitada e só então encerra a mensagem atual.

O EventBridge Scheduler envia uma mensagem `MAINTENANCE` a cada dois minutos. Esse fluxo não reenfileira jobs de processamento. O SQS já mantém a mensagem de forma durável e a reapresenta após o visibility timeout se o consumidor cair antes do `DeleteMessage`. Evitar requeue pelo maintenance remove uma fonte de processamento duplicado e de carga desnecessária no PostgreSQL.

O maintenance executa apenas limpeza limitada de estado terminal:

1. jobs `CONSUMED` são elegíveis para remoção uma hora após a materialização do campeonato;
2. jobs `COMPLETED`, `FAILED` e `CANCELLED` só são removidos depois de `expires_at`;
3. cada execução remove no máximo 25 jobs, com `FOR UPDATE SKIP LOCKED`, evitando picos de I/O.

O SQS usa long polling e visibility timeout explícito. Enquanto um passo está em execução, o worker renova o `heartbeat_at` do job e a visibilidade da mensagem em aproximadamente um terço do timeout configurado. Se ocorrer falha de transporte ou processo antes da exclusão da mensagem, o retry é feito pelo próprio SQS; depois do limite de redrive, a mensagem segue para a DLQ.

### Motor da prévia

A primeira implementação AWS simplificada (`aws-structural-v1`) foi descartada antes do cutover porque não reproduzia integralmente o comportamento do motor exato v8 já validado no Supabase.

A LAJE-126 passa a portar para o RDS o motor exato v8 necessário à prévia e à materialização do chaveamento:

- schema transitório `championship_bracket_preview_private`;
- tabelas, índices, constraints, funções e triggers do motor v8;
- helpers públicos estritamente necessários ao cálculo;
- funções de status, consulta por dia e criação final do campeonato;
- shim de identidade `auth.uid()` baseado em `laje.request_user_id`, definido apenas para compatibilidade das funções portadas.

Não são portados `pgmq`, `pg_cron`, Edge Functions, Vault ou dados históricos do schema privado. `enqueue` vira apenas um ponto de compatibilidade sem fila local; a fila real é Amazon SQS e a orquestração é da `laje-api`.

As migrations carregam somente definição estrutural e código SQL. Nenhuma linha de job/slot/assignment do Supabase é copiada para o RDS. O estado transitório do motor AWS começa vazio e passa a existir apenas quando o frontend AWS-only solicitar uma nova prévia.

## Feed iCalendar

O endpoint público é:

```text
GET /api/v1/calendar-subscription-feed
```

Ele suporta os mesmos escopos do fluxo legado:

- `MATCH`;
- `SESSION`;
- `SPORT_NAIPE`;
- `TEAM`;
- `TEAM_MATCHES`;
- `TEAM_SPORT_NAIPE`.

A consulta ocorre diretamente no PostgreSQL/RDS, respeita bloqueio da página pública, inclui somente eventos futuros programados, gera calendário ICS com timezone `America/Sao_Paulo`, ETag e cache privado de cinco minutos.

No deployment AWS-only, o frontend monta a URL usando `VITE_API_URL`. No deployment legado, continua usando a Edge Function até o cutover.

## E-mails de reserva

No provider AWS, a criação e a revisão de solicitações de reserva disparam a notificação no backend, e não mais pelo navegador.

O serviço usa Brevo via HTTPS. O valor de `BREVO_API_KEY` deve ser injetado em runtime pelo AWS Secrets Manager; a chave nunca é versionada.

Variáveis operacionais:

```text
MAIL_ENABLED
BREVO_API_KEY
MAIL_FROM
MAIL_FROM_NAME
CO_EVENTS_EMAIL
CO_PRESIDENCY_EMAIL
APP_URL
```

Falha de entrega de e-mail não desfaz a transação de reserva. O erro é registrado no log da aplicação para investigação, preservando o dado de negócio.

No staging, `MAIL_ENABLED` pode permanecer `false` enquanto a credencial Brevo não estiver provisionada. A ativação exige um ARN de secret válido. A lógica de montagem e chamada é coberta por testes; uma entrega real deverá ser evidenciada antes do cutover produtivo.

## IAM e Secrets Manager

A task ECS recebe uma task role específica com o mínimo necessário para a fila de preview:

- `sqs:SendMessage`;
- `sqs:ReceiveMessage`;
- `sqs:DeleteMessage`;
- `sqs:ChangeMessageVisibility`;
- `sqs:GetQueueAttributes`.

A execution role continua responsável por buscar os secrets injetados na task definition. O segredo Brevo só entra na política/definição quando `staging_mail_enabled=true`.

Não há access key AWS estática no runtime nem service role do Supabase.

## Observabilidade

A implementação adiciona:

- CloudWatch Logs da própria `laje-api`;
- alarme quando a DLQ contém mensagem;
- alarme quando a mensagem mais antiga da fila supera cinco minutos;
- alarme quando o RDS de staging fica abaixo de 5 GiB livres;
- alarme quando a CPU média do RDS de staging permanece acima de 80% por 15 minutos;
- métricas nativas do SQS e RDS;
- estado do EventBridge Scheduler reproduzível via Terraform.

Logs de erro incluem falhas do consumidor, identificador da mensagem e receive count sem registrar payloads sensíveis.

## Deploy e migrations

A portabilidade do motor exato é incremental e permanece fora do baseline. As migrations da LAJE-126 começam em `20261007160300` e terminam em `20261007161000`, cobrindo limpeza do protótipo público, helpers, schema privado, funções, triggers e contratos de API.

Durante o deploy de staging, uma task Fargate efêmera executa o runner antes de iniciar/atualizar o serviço principal. O runner:

- mantém um registro idempotente em `laje_api_internal.operational_migrations`, fora do schema `public`;
- ignora migrations já aplicadas;
- separa SQL respeitando funções dollar-quoted, strings e comentários;
- executa cada migration em transação própria;
- não abre conectividade PostgreSQL pública.

### Proteção de armazenamento e carga

A migração foi ajustada para não transformar a coexistência em duplicação descontrolada:

- `migration:sync-data` continua exportando somente o schema `public`; `championship_bracket_preview_private` nunca entra no dump de dados;
- não existe replicação contínua nem dual-write Supabase -> RDS nesta etapa;
- o dump é transmitido por pipe `pg_dump -> psql`, sem arquivo intermediário;
- antes de sincronizar, o script mede origem e destino e aplica um orçamento conservador;
- por padrão, o sync é bloqueado se o `public` da origem ultrapassar 256 MiB ou se a projeção conservadora do destino ultrapassar 2 GiB; os limites só podem ser ampliados explicitamente por `MIGRATION_MAX_SOURCE_PUBLIC_BYTES` e `MIGRATION_MAX_DESTINATION_DATABASE_BYTES`;
- payloads de prévia acima de 2 MiB são recusados antes de escrever no PostgreSQL;
- estado transitório consumido/expirado é apagado em batches pequenos pelo maintenance.

Esses limites são guardrails operacionais, não cotas do provedor. Qualquer revisão deve ser baseada nas métricas atuais e na capacidade provisionada do RDS.

## Evidência histórica de validação — 07/10/2026

A branch `LAJE-126` foi implantada temporariamente nos recursos AWS então nomeados como staging para validar a portabilidade do motor exato v8 e os workloads operacionais. Os resultados abaixo descrevem somente aquela janela.

Validações concluídas:

- migrations `20261007160300..161000` aplicadas por task Fargate efêmera;
- schema privado validado com 27 tabelas e 73 funções no RDS;
- banco de staging medido em aproximadamente 45 MB, com cerca de 0,7 MB no schema privado de preview e nenhum job ativo após o smoke;
- `pgmq` e `pg_cron` não estão instalados no runtime alvo;
- a tabela pública obsoleta `championship_bracket_preview_jobs` não existe no RDS;
- `/api/v1/health` respondeu com serviço saudável;
- `/api/v1/health/database` confirmou PostgreSQL alcançável;
- CORS validado para `https://laje-tcc.vercel.app`;
- smoke core concluiu com 3 campeonatos, 442 jogos, 239 linhas de standings, 3 edições e 19 competições;
- SQS principal usa long polling de 20 s, visibility timeout de 180 s e redrive para DLQ após 5 tentativas;
- DLQ permaneceu sem backlog durante a validação;
- EventBridge Scheduler executou `MAINTENANCE` a cada 2 minutos;
- o maintenance não reenfileirou jobs e os logs registraram `Bracket preview maintenance completed; requeued=0.`;
- alarmes de DLQ, idade da fila, CPU do RDS e espaço livre do RDS ficaram em `OK`;
- o RDS manteve aproximadamente 18,28 GB de espaço livre durante a janela de validação;
- CI, PostgreSQL Validation, Docker Image, Terraform e CI do frontend AWS-only passaram;
- os guardrails de storage foram testados no CI e bloquearam a sincronização antes de qualquer escrita destrutiva quando configurados com limites deliberadamente insuficientes;
- o trust OIDC temporário da branch `LAJE-126` foi removido depois da validação.

O sync descrito no ensaio era restrito ao schema `public`, sem replicação contínua nem cópia do schema transitório `championship_bracket_preview_private`.

Na configuração histórica dessa validação, o envio Brevo estava desabilitado até existir remetente verificado e secret `BREVO_API_KEY` provisionado no Secrets Manager. A entrega transacional atual deve ser verificada no runtime e demonstrada antes de afirmar que o e-mail está operacional.

## Operação na versão TCC

O frontend `laje-tcc` consome a `laje-api` pela API Gateway, VPC Link, ALB interno e ECS/Fargate. A API acessa o RDS selecionado para a entrega; os workloads assíncronos usam SQS/DLQ e EventBridge conforme a configuração versionada. Confira os health checks, alarmes definidos e smoke da publicação correspondente antes de usar a execução como evidência.

## Relação com o Portfólio

A solução reforça os requisitos de Web Apps do projeto:

- backend e workloads sob infraestrutura de nuvem controlada;
- CI/CD e infraestrutura versionados;
- observabilidade via CloudWatch;
- separação de responsabilidades entre frontend, API, fila e banco;
- segredos fora do repositório;
- evidência de Pull Request e revisão por pares.

A Vercel hospeda o frontend `laje-tcc` conforme a exceção aprovada para este projeto.
