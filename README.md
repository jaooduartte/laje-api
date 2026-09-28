# LAJE API

API dedicada do LAJE App, responsável por centralizar as regras de negócio,
autenticação, persistência de dados e comunicação entre o frontend e a
infraestrutura PostgreSQL.

## Arquitetura

Estado-alvo definido na LAJE-82:

```text
Frontend React/Vite (Vercel)
↓
HTTPS / REST
↓
Application Load Balancer (AWS)
↓
LAJE API (Node.js + Express em Amazon ECS/AWS Fargate)
↓
Amazon RDS for PostgreSQL 17
```

A arquitetura detalhada, incluindo ambientes, rede, TLS/CORS, secrets,
observabilidade e decisões de custo, está em [docs/architecture.md](docs/architecture.md).
O registro formal da decisão está em
[docs/adr/0001-arquitetura-operacional-final.md](docs/adr/0001-arquitetura-operacional-final.md).

## Ambientes

### Produção LAJE durante a migração

A aplicação atualmente utilizada pela LAJE permanece utilizando o frontend na
Vercel e a infraestrutura existente baseada em Supabase até o cutover planejado.
Essa produção não deve ser alterada pelas tarefas de staging AWS.

### Integration / staging

O ambiente de integração utiliza o mesmo repositório frontend `laje`, com
`VITE_API_URL` apontando para a `laje-api` em AWS. Backend e banco utilizam a
arquitetura alvo com ECS/Fargate e Amazon RDS for PostgreSQL 17.

### Produção alvo

O frontend permanece na Vercel por decisão externa específica aprovada para o
projeto. O backend, persistência e serviços operacionais passam para AWS. Após o
cutover, o frontend deixa de usar Supabase como backend principal e passa a
consumir a `laje-api` pela URL produtiva configurada no ambiente.

## Stack

- Node.js
- TypeScript
- Express
- PostgreSQL 17
- Docker
- Amazon ECS / AWS Fargate
- Amazon ECR
- Amazon RDS for PostgreSQL
- Application Load Balancer
- AWS Secrets Manager
- Amazon CloudWatch
- GitHub Actions

## Desenvolvimento

Requer Node.js 22 ou superior.

Principais comandos:

```bash
npm run dev
npm run build
npm start
npm run typecheck
npm run lint
npm run format:check
npm test
npm run test:unit
npm run test:e2e
npm run test:coverage
```

`npm start` executa o build automaticamente antes de iniciar `dist/server.js`.
Os testes usam o runner nativo do Node com suporte TypeScript via `tsx`.

## Container

A imagem Docker multi-stage e o fluxo de execução com PostgreSQL gerenciado estão
documentados em [docs/containerization.md](docs/containerization.md). O container
recebe toda configuração em runtime, executa como usuário não-root e não exige um
serviço PostgreSQL local via Docker Compose.

O baseline PostgreSQL reproduzível está documentado em
[docs/migration/database-baseline.md](docs/migration/database-baseline.md).
As instruções completas de setup e migração serão consolidadas nas tarefas de
documentação correspondentes.
