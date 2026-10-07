# Workloads operacionais AWS — LAJE-126

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

Os componentes legados permanecem intactos durante a coexistência. Eles só podem ser desligados/removidos no cutover controlado da LAJE-139.

## Prévia assíncrona de chaveamento

### Fluxo

```text
Frontend AWS-only
  -> POST laje-api preview-jobs
  -> PostgreSQL/RDS: championship_bracket_preview_jobs
  -> Amazon SQS
  -> worker Node na task ECS/Fargate
  -> PostgreSQL/RDS: resultado/diagnósticos
  -> frontend consulta status/dia pela laje-api
```

A fila principal possui DLQ e política de redrive. A entrega é tratada como at-least-once: o worker só processa jobs em estado `QUEUED`; uma repetição de mensagem para job já concluído é inócua.

O EventBridge Scheduler envia uma mensagem `MAINTENANCE` a cada dois minutos. O worker então:

1. identifica jobs em processamento com heartbeat antigo;
2. devolve esses jobs para `QUEUED`;
3. remove registros terminais expirados.

O recovery não publica uma segunda mensagem para jobs já representados na fila. A mensagem SQS original volta a ficar visível após o visibility timeout, evitando duplicação artificial de tentativas.

O SQS é configurado com long polling e visibility timeout explícito. Em erro de processamento, o job volta para `QUEUED` enquanto houver tentativas disponíveis e a mensagem não é removida, permitindo o retry nativo do SQS. No limite configurado de tentativas, o job passa para `FAILED` e a política de redrive move a mensagem para a DLQ.

### Motor da prévia

O frontend já calcula `structural_schedule_slots` antes da prévia exata. A implementação AWS `aws-structural-v1` usa essa estrutura como skeleton determinístico:

- fase de grupos: combinações round-robin são associadas sequencialmente aos slots estruturais da competição;
- mata-mata: os slots são preservados como partidas projetadas, pois os participantes dependem de resultados futuros;
- falta de capacidade estrutural vira diagnóstico impeditivo;
- payload, dependências e resultado recebem assinaturas SHA-256 para deduplicação e rastreabilidade.

A implementação deliberadamente não copia para o RDS o schema privado/RPCs do Supabase. Regra operacional e orchestration ficam na API; o PostgreSQL persiste estado e resultado.

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
- métricas nativas do SQS;
- estado do EventBridge Scheduler reproduzível via Terraform.

Logs de erro incluem falhas do consumidor, identificador da mensagem e receive count sem registrar payloads sensíveis.

## Deploy e migration

A tabela operacional de preview é uma migration incremental, não uma alteração retroativa de baseline:

```text
infra/database/migrations/20261007160000_create_championship_bracket_preview_jobs.sql
```

Durante o deploy de staging, uma task Fargate efêmera executa o runner de migrations antes de iniciar/atualizar o serviço principal. O banco continua privado; não é aberta conectividade PostgreSQL pública para aplicar a migration.

## Evidência de staging — 07/10/2026

A branch `LAJE-126` foi implantada temporariamente no staging AWS para validação antes do corte de tráfego.

Validações concluídas:

- migration incremental aplicada por task Fargate efêmera;
- `/api/v1/health` respondeu com serviço saudável;
- `/api/v1/health/database` confirmou PostgreSQL alcançável;
- CORS validado para `https://laje-tcc.vercel.app`;
- smoke core concluiu com 3 edições e 19 competições carregadas;
- SQS principal com long polling de 20 s, visibility timeout de 180 s e redrive para DLQ após 5 tentativas;
- DLQ permaneceu vazia durante a validação;
- EventBridge Scheduler executou `MAINTENANCE` a cada 2 minutos;
- CloudWatch registrou mensagens enviadas, recebidas e removidas na mesma cadência, sem backlog;
- logs do worker registraram repetidamente `Bracket preview maintenance completed; requeued=0.`;
- alarmes `laje-staging-bracket-preview-dlq-not-empty` e `laje-staging-bracket-preview-oldest-message` ficaram em `OK`;
- task ECS/Fargate executou com 1 instância durante o smoke e foi suspensa após a validação;
- scheduler foi desabilitado junto com a suspensão do runtime para evitar processamento/custo desnecessário fora da janela de testes;
- CI da `laje-api`, validação Terraform, imagem Docker e CI do frontend AWS-only passaram.

O envio Brevo permanece propositalmente desabilitado no staging até existir remetente verificado e secret `BREVO_API_KEY` provisionado no Secrets Manager. Isso não bloqueia a migração de código, mas uma entrega transacional real deve ser evidenciada antes da LAJE-139.

## Coexistência e cutover

Antes da LAJE-139:

- produção legada continua usando Supabase;
- `laje-tcc` usa os contratos AWS;
- Edge Functions/pgmq/pg_cron legados não são removidos;
- nenhuma fila AWS recebe tráfego produtivo definitivo.

No cutover:

1. confirmar LAJE-126 e LAJE-89 concluídas;
2. executar paridade final e write freeze da LAJE-139;
3. apontar o frontend final para a API AWS;
4. validar filas, calendário e e-mails;
5. só então desativar jobs/funções equivalentes no Supabase.

## Relação com o Portfólio

A solução reforça os requisitos de Web Apps do projeto:

- backend e workloads sob infraestrutura de nuvem controlada;
- CI/CD e infraestrutura versionados;
- observabilidade via CloudWatch;
- separação de responsabilidades entre frontend, API, fila e banco;
- segredos fora do repositório;
- evidência de Pull Request e revisão por pares.

A Vercel permanece apenas como frontend conforme autorização externa específica do projeto.
