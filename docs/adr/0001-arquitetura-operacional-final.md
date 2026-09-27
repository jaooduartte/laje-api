# ADR 0001 — Arquitetura operacional final do LAJE

- Status: Accepted
- Data: 2026-09-27
- Tarefa: LAJE-82
- Escopo: frontend, backend, banco, rede, segurança, CI/CD e observabilidade

## Contexto

O LAJE opera hoje com frontend React/Vite hospedado na Vercel e forte dependência do Supabase para persistência, autenticação, realtime e parte das regras de negócio. A evolução do projeto prevê um backend dedicado em `laje-api`, PostgreSQL gerenciado e infraestrutura operacional sob controle explícito do projeto.

O Portfolio Playbook vigente exige arquitetura documentada, CI/CD, ambiente público, observabilidade, histórico de decisões e domínio técnico da infraestrutura. O Playbook público classifica Vercel como `Não Usar`; entretanto, existe uma decisão externa específica e já aprovada para o LAJE permitindo manter o frontend na Vercel. Esta exceção não é uma regra derivada do Playbook e deve ser tratada como autorização específica do projeto.

A arquitetura precisa permitir migração incremental sem interromper a produção atual no Supabase.

## Decisão

Adotar a seguinte arquitetura alvo:

```text
Frontend React/Vite (Vercel)
        |
        | HTTPS
        v
Application Load Balancer
        |
        v
Amazon ECS / AWS Fargate
laje-api Node.js + Express
        |
        v
Amazon RDS for PostgreSQL 17
```

Serviços complementares:

- Amazon ECR para imagens da API;
- AWS Certificate Manager para TLS do endpoint da API;
- AWS Secrets Manager para credenciais e segredos;
- Amazon CloudWatch para logs, métricas e alarmes;
- GitHub Actions autenticado na AWS por OIDC para CI/CD;
- Amazon SQS/DLQ e EventBridge Scheduler nas etapas previstas pela LAJE-126.

A região alvo é `sa-east-1`.

## Ambientes

### Legado durante a migração

- frontend atual na Vercel;
- Supabase permanece como backend/banco da produção em uso;
- nenhuma etapa de staging AWS pode alterar esse ambiente sem uma tarefa explícita de cutover.

### Integration/staging

- mesmo repositório frontend `laje`;
- projeto/ambiente Vercel dedicado quando necessário;
- `VITE_API_URL` aponta para a API AWS de staging;
- serviço ECS/Fargate de staging;
- RDS PostgreSQL 17 dedicado a staging.

### Produção alvo

- frontend `laje` na Vercel;
- `VITE_API_URL` aponta para a `laje-api` de produção;
- ECS/Fargate de produção;
- RDS PostgreSQL 17 de produção separado do staging;
- Supabase deixa de ser o backend principal após o cutover.

## Rede

A VPC usa pelo menos duas Availability Zones.

- ALB em subnets públicas;
- ECS/Fargate em subnets privadas;
- RDS em subnets privadas de banco;
- Security Group do ALB aceita apenas HTTP para redirect e HTTPS público;
- Security Group do ECS aceita apenas tráfego proveniente do ALB;
- Security Group do RDS aceita PostgreSQL somente do ECS e de acessos administrativos temporários explicitamente autorizados;
- PostgreSQL nunca deve ser exposto com `0.0.0.0/0`.

O mecanismo de saída das subnets privadas será definido no provisionamento entre NAT Gateway e endpoints VPC necessários, priorizando menor custo sem tornar as tasks diretamente expostas para entrada pública.

## Banco de dados

Escolha: Amazon RDS for PostgreSQL 17.

Motivos:

- compatibilidade com o baseline da LAJE-112;
- migração PostgreSQL -> PostgreSQL com menor superfície de incompatibilidade;
- operação gerenciada de backups, storage e manutenção;
- menor complexidade que Aurora para o porte atual do sistema.

Staging inicia Single-AZ. Produção também inicia Single-AZ por restrição de custo, com backups automáticos, snapshots antes de mudanças destrutivas, criptografia em repouso, TLS e deletion protection. Multi-AZ é uma evolução quando disponibilidade ou orçamento justificarem.

## Runtime da API

Escolha: Amazon ECS com AWS Fargate, atrás de Application Load Balancer.

Motivos:

- execução containerizada sem administração de hosts EC2;
- integração com ECR, IAM, Secrets Manager e CloudWatch;
- health checks e substituição de tasks não saudáveis;
- capacidade de escalar `desiredCount` durante eventos;
- deploy rolling como estratégia inicial;
- possibilidade futura de blue/green sem trocar de plataforma.

Staging começa com uma task. Produção pode começar com uma task e aumentar para duas ou mais conforme tráfego e orçamento.

## Segurança

- HTTPS obrigatório no endpoint da API;
- conexão API -> RDS usando TLS;
- segredo de banco e integrações no Secrets Manager;
- IAM/task role com menor privilégio;
- GitHub Actions usa OIDC em vez de AWS access keys permanentes;
- CORS com allowlist explícita por ambiente;
- sem wildcard de origem em endpoints autenticados;
- nenhuma credencial de backend em variáveis `VITE_*`.

## CI/CD

Fluxo alvo:

1. branch `LAJE-xxx`;
2. pull request;
3. quality gate do GitHub Actions;
4. merge em `main`;
5. build da imagem Docker;
6. push no ECR;
7. atualização do ECS Service;
8. validação por healthcheck do ALB;
9. observação por CloudWatch.

O workflow placeholder atual não é considerado deploy funcional e é tratado pela LAJE-129.

## Observabilidade

CloudWatch é o baseline operacional para:

- logs estruturados da `laje-api`;
- métricas do ECS/Fargate;
- health checks e métricas do ALB;
- métricas de conexões, storage e carga do RDS;
- alarmes de indisponibilidade e pressão relevante de recursos.

A LAJE-40 detalha dashboard, retenção, alertas e evidências finais do ambiente publicado.

## Decisão financeira

O desenho busca reduzir custo fixo e administração sem abrir mão de controle arquitetural.

Decisões de custo:

- Fargate em vez de EC2 dedicado para evitar capacidade ociosa e manutenção de servidor;
- RDS PostgreSQL padrão em vez de Aurora;
- Single-AZ inicialmente em staging e produção;
- uma task por ambiente no início, com scale-out sob demanda;
- staging reduzido ou desligado fora das janelas de migração quando isso for seguro;
- retenção explícita de logs;
- dimensionamento de NAT/endpoints somente após estimativa na LAJE-127;
- tags `Project=LAJE` e `Environment=staging|production` para rastreabilidade de custo;
- AWS Budgets configurado no provisionamento.

Valores absolutos não são congelados neste ADR porque preço, classe e disponibilidade mudam. Antes de criar recursos permanentes, a LAJE-127 deve registrar o dimensionamento e a estimativa corrente no AWS Pricing Calculator.

## Alternativas consideradas

### PostgreSQL local com Docker Compose

Rejeitada como requisito operacional. O CI já valida o baseline com PostgreSQL 17 efêmero e o ambiente de integração real será o RDS. Docker continua aplicável à imagem da API.

### Amazon EC2 para a API

Não escolhido inicialmente. EC2 oferece maior controle do host, mas exige patching, gestão de instância e capacidade ociosa. Fargate atende ao porte atual com menor sobrecarga operacional.

### AWS App Runner / plataformas equivalentes

Não escolhido. Embora simplifique publicação, abstrai mais componentes da operação. ECS/Fargate torna rede, runtime, imagem, healthcheck e deploy mais explícitos para o projeto e para a sustentação técnica do TCC.

### Amazon Aurora PostgreSQL

Não escolhido para a primeira versão. O porte atual não justifica a complexidade/custo adicional em relação ao RDS PostgreSQL padrão.

### Migrar frontend para AWS

Não escolhido. O frontend permanecerá na Vercel por decisão externa específica aprovada para o projeto. Essa exceção deve continuar documentada porque diverge do texto público do Playbook.

## Consequências

Positivas:

- separação clara entre frontend, API e persistência;
- redução do acoplamento ao Supabase;
- banco reproduzível por baseline/migrations;
- deploy e operação demonstráveis na banca;
- observabilidade e segurança centralizadas na AWS;
- migração incremental com staging isolado.

Negativas/trade-offs:

- ALB, RDS e networking geram custo mesmo com carga baixa;
- Single-AZ reduz custo, mas não oferece failover automático do banco;
- Vercel permanece como exceção documental ao Playbook público;
- a operação passa a exigir conhecimento de IAM, ECS, RDS, rede e observabilidade;
- coexistência temporária Supabase + AWS aumenta complexidade até o cutover.

## Validação da decisão

A arquitetura deve ser considerada implementada somente quando as tarefas dependentes entregarem evidências reais:

- LAJE-127: RDS staging + baseline validado;
- LAJE-131: container da API;
- LAJE-107/109: conexão e healthchecks;
- LAJE-33: deploy automatizado;
- LAJE-40: observabilidade;
- LAJE-88: migração/cutover;
- LAJE-89 e LAJE-126: realtime e workloads assíncronos.

## Referências

- Arquitetura detalhada: `docs/architecture.md`
- Baseline PostgreSQL: `docs/migration/database-baseline.md`
- Portfolio Playbook — Geral: https://github.com/CatolicaSC-Portfolio/The-Portfolio-Playbook/blob/main/directions/portfolio-directions-GERAL.md
- Portfolio Playbook — Web Apps: https://github.com/CatolicaSC-Portfolio/The-Portfolio-Playbook/blob/main/directions/portfolio-directions-webapp.md
- RDS PostgreSQL versions: https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html
- RDS PostgreSQL SSL/TLS: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.Security.html
- ECS deployment workflow: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/blue-green-deployment-how-it-works.html
