# LAJE API

API dedicada da Liga das Atléticas de Joinville (LAJE), responsável por centralizar regras de negócio, autenticação, autorização, persistência e contratos HTTP entre o frontend e a infraestrutura PostgreSQL.

> A migração é incremental. Enquanto o cutover não for concluído, a produção utilizada pela LAJE continua no ambiente atual baseado em Supabase. O repositório `laje-api` representa o backend da arquitetura alvo e não deve provocar alterações na produção legada fora das tarefas de migração correspondentes.

## Arquitetura alvo

Estado-alvo definido na LAJE-82:

```text
Frontend React/Vite (Vercel — exceção aprovada para o projeto)
        |
        | HTTPS / REST
        v
Application Load Balancer (AWS)
        |
        v
LAJE API (Node.js + Express em Amazon ECS/AWS Fargate)
        |
        v
Amazon RDS for PostgreSQL 17
```

A arquitetura detalhada, incluindo ambientes, rede, TLS/CORS, secrets, observabilidade e decisões de custo, está em [docs/architecture.md](docs/architecture.md). O registro formal da decisão está em [docs/adr/0001-arquitetura-operacional-final.md](docs/adr/0001-arquitetura-operacional-final.md).

A Vercel permanece somente como hospedagem do frontend por uma exceção específica aprovada externamente para o projeto. Backend, banco, regras de negócio e serviços operacionais do estado final ficam sob a arquitetura AWS controlada pelo projeto.

## Estados operacionais da migração

<!-- prettier-ignore -->
| Estado | Frontend | Backend principal | Banco principal | Finalidade |
| --- | --- | --- | --- | --- |
| Produção atual durante a migração | Vercel, repositório `laje` | Supabase | PostgreSQL do Supabase | Preservar a operação real até o cutover |
| Integration / staging | Mesmo repositório `laje`, ambiente dedicado | `laje-api` em AWS | Amazon RDS PostgreSQL 17 | Validar API, migrations, contratos, CORS, TLS, deploy e migração |
| Produção alvo | Vercel, repositório `laje` | `laje-api` em AWS | Amazon RDS PostgreSQL 17 | Estado final após cutover |

No frontend, `VITE_API_URL` seleciona a API correspondente ao ambiente. No backend, desenvolvimento/CI podem usar `DATABASE_URL`; no ECS staging, host, banco, usuário e senha são injetados separadamente em runtime para que o usuário/senha permaneçam no Secrets Manager e a própria aplicação componha a URL PostgreSQL com escaping seguro. A troca de ambiente ocorre por configuração, sem alteração de código e sem versionar credenciais.

## Stack

- Node.js 22+
- TypeScript
- Express
- PostgreSQL 17
- OpenAPI 3.1 / Swagger UI para documentação de desenvolvimento
- Docker
- Amazon ECS / AWS Fargate
- Amazon ECR
- Amazon RDS for PostgreSQL
- Application Load Balancer
- AWS Secrets Manager
- Amazon CloudWatch
- GitHub Actions

## Pré-requisitos para desenvolvimento

- Git;
- Node.js 22 ou superior;
- npm;
- acesso a uma instância PostgreSQL 17 compatível com o ambiente que será validado.

Não existe requisito de manter um PostgreSQL local permanente nem um `docker-compose` de banco. Em CI, o PostgreSQL 17 é criado de forma efêmera. Para desenvolvimento, use uma instância PostgreSQL 17 controlada por você ou um ambiente autorizado. O RDS de staging é privado e não deve ser tornado público para facilitar execução local.

## Instalação

```bash
git clone https://github.com/jaooduartte/laje-api.git
cd laje-api
npm ci
cp .env.example .env
```

Depois de copiar o arquivo de exemplo, configure pelo menos:

```text
NODE_ENV=development
PORT=3000
DATABASE_URL=postgresql://<usuario>:<senha>@<host>:5432/<database>?sslmode=<modo>
CORS_ORIGINS=http://localhost:8080
```

`DATABASE_URL` continua sendo a forma recomendada para desenvolvimento e CI. Em runtime AWS, ela pode ser substituída por `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_PORT` e `DATABASE_SSLMODE`; todos os quatro primeiros componentes obrigatórios devem estar presentes. O staging injeta usuário/senha diretamente do Secrets Manager. Credenciais reais, tokens e valores do AWS Secrets Manager nunca devem ser adicionados ao repositório, ao README ou à imagem Docker.

Para um PostgreSQL de desenvolvimento sem TLS, o ambiente controlado pode utilizar `sslmode=disable`. Em AWS/RDS, a conexão deve usar TLS; consulte [docs/database-access.md](docs/database-access.md).

## Preparar um banco PostgreSQL 17 vazio

Quando o ambiente de desenvolvimento utilizar um banco vazio, aplique o baseline estrutural:

```bash
psql "$DATABASE_URL" \
  --set ON_ERROR_STOP=1 \
  --file infra/database/baseline/schema.sql
```

Valide a estrutura:

```bash
psql "$DATABASE_URL" \
  --set ON_ERROR_STOP=1 \
  --file infra/database/baseline/validate.sql
```

O baseline não contém dados produtivos, Supabase Auth, Storage, Realtime, policies RLS específicas da plataforma, Edge Functions ou jobs operacionais. Detalhes estão em [docs/migration/database-baseline.md](docs/migration/database-baseline.md).

## Executar a API

Modo de desenvolvimento com reload:

```bash
npm run dev
```

Build e execução do artefato compilado:

```bash
npm run build
npm start
```

No startup, a aplicação valida a conexão PostgreSQL antes de abrir a porta HTTP. Se `DATABASE_URL` estiver ausente ou o banco estiver inacessível, a inicialização deve falhar em vez de disponibilizar uma API parcialmente funcional.

## Validar a execução

Com a API em execução na porta padrão:

```bash
curl --fail http://127.0.0.1:3000/api/v1/health
curl --fail http://127.0.0.1:3000/api/v1/health/database
```

- `/api/v1/health`: saúde do processo HTTP;
- `/api/v1/health/database`: conectividade da aplicação com o PostgreSQL.

Os detalhes de semântica e respostas estão em [docs/healthchecks.md](docs/healthchecks.md).

## OpenAPI e convenções HTTP

Com `NODE_ENV=development`, a documentação é montada somente para o ambiente local de desenvolvimento:

```text
http://127.0.0.1:3000/api-docs
http://127.0.0.1:3000/api-docs/openapi.json
```

`/api-docs` fornece a interface Swagger UI e `/api-docs/openapi.json` expõe a especificação OpenAPI 3.1 servida pela própria aplicação. Os healthchecks existentes fazem parte do documento OpenAPI.

A documentação não é montada automaticamente em `test` nem em `production`. As convenções de sucesso, erro, status codes, paginação, filtros, versionamento e autenticação futura estão em [docs/api-conventions.md](docs/api-conventions.md) e devem orientar a LAJE-84 e os módulos de negócio seguintes.

## Scripts

<!-- prettier-ignore -->
| Comando | Finalidade |
| --- | --- |
| `npm run dev` | Executa o servidor TypeScript em modo watch |
| `npm run build` | Compila TypeScript para `dist/` |
| `npm start` | Compila e inicia `dist/server.js` |
| `npm run typecheck` | Valida tipos sem emitir arquivos |
| `npm run lint` | Executa ESLint com zero warnings permitidos |
| `npm run format:check` | Valida formatação com Prettier |
| `npm test` | Executa testes unitários e E2E |
| `npm run test:unit` | Executa testes unitários |
| `npm run test:e2e` | Executa testes E2E |
| `npm run test:integration` | Executa integração contra PostgreSQL configurado |
| `npm run test:coverage` | Executa testes com relatório de cobertura |

Antes de abrir uma PR, o conjunto mínimo esperado é:

```bash
npm run typecheck
npm run lint
npm run format:check
npm test
npm run build
```

O GitHub Actions também valida integração e baseline com PostgreSQL 17 e realiza build/execução real da imagem Docker.

## Container

A imagem Docker multi-stage, o healthcheck e o fluxo de execução com PostgreSQL externo estão documentados em [docs/containerization.md](docs/containerization.md).

Build local da imagem:

```bash
docker build -t laje-api:local .
```

O container recebe configuração em runtime, executa como usuário não-root e não incorpora `.env` ou credenciais. Não existe serviço PostgreSQL local permanente obrigatório no fluxo oficial.

## Estrutura do repositório

```text
src/
  common/       constantes e middlewares compartilhados
  config/       validação e acesso às configurações
  database/     client, adapter PostgreSQL, transações e abstrações de repository
  modules/      módulos de domínio e infraestrutura, incluindo healthchecks
  openapi/      documento OpenAPI e rotas da documentação de desenvolvimento
  routes/       composição das rotas versionadas
  server.ts     bootstrap e lifecycle do processo

tests/
  unit/         testes unitários
  e2e/          testes HTTP/E2E
  integration/  testes com PostgreSQL real/efêmero

docs/
  adr/          decisões arquiteturais
  migration/    inventário, baseline e estratégia de migração
  *.md          arquitetura, contratos HTTP, banco, healthchecks e containerização

infra/
  database/     baseline e migrations PostgreSQL
  aws/          estrutura reservada para infraestrutura AWS
```

## Documentação técnica e de migração

A migração deve ser tratada como uma sequência rastreável, não como um dump direto do Supabase para produção:

- [Convenções HTTP](docs/api-conventions.md): formato de contratos, status codes, paginação, filtros, versionamento e autenticação futura;
- [Inventário do Supabase](docs/migration/supabase-inventory.md): fotografia dos objetos e dependências do backend atual;
- [Baseline PostgreSQL](docs/migration/database-baseline.md): estrutura reproduzível para PostgreSQL 17;
- [Estratégia de migração](docs/migration/migration-strategy.md): fases, coexistência, cutover e responsabilidades;
- [Acesso PostgreSQL](docs/database-access.md): contratos da camada de persistência e requisitos de conexão;
- [Healthchecks](docs/healthchecks.md): semântica dos endpoints operacionais;
- [Staging AWS](docs/staging-aws.md): topologia, operação e evidências E2E da LAJE-136;
- [Workloads operacionais AWS](docs/operational-workloads.md): SQS/DLQ, EventBridge, e-mail, calendário e observabilidade da LAJE-126;
- [Arquitetura operacional](docs/architecture.md): estado-alvo Vercel + AWS + RDS;
- [ADR da arquitetura](docs/adr/0001-arquitetura-operacional-final.md): decisão formal e trade-offs.

Tarefas principais relacionadas no Jira:

- `LAJE-83`: base inicial do repositório `laje-api`;
- `LAJE-84`: contratos dos três fluxos prioritários;
- `LAJE-85`: autenticação, autorização e auditoria;
- `LAJE-86`: campeonatos, jogos, standings e bracket;
- `LAJE-87`: eventos, links e configurações públicas;
- `LAJE-88`: migração de schema/dados, ensaios, cutover e rollback;
- `LAJE-89`: substituição do realtime;
- `LAJE-115`: OpenAPI e convenções HTTP;
- `LAJE-126`: jobs, filas, cron e Edge Functions na AWS;
- `LAJE-127`: ambiente AWS/RDS de integration/staging;
- `LAJE-131`: containerização para execução/deploy AWS;
- `LAJE-136`: publicação e validação E2E do staging AWS;
- `LAJE-33`: CI/CD final entre frontend Vercel e backend AWS;
- `LAJE-37`: documentação do deploy final.

## Regras de segurança e evolução

- não versionar `.env`, credenciais, tokens, chaves de serviço ou dumps produtivos;
- manter o RDS privado;
- usar AWS Secrets Manager/IAM para secrets e permissões no ambiente AWS;
- não alterar retroativamente o baseline consolidado: mudanças futuras de schema devem ser novas migrations em `infra/database/migrations/`;
- não executar cutover ou alterar a produção Supabase sem a tarefa de migração correspondente, plano de validação e rollback;
- não reintroduzir acesso direto do frontend ao banco no estado final;
- não publicar exemplos OpenAPI contendo tokens, credenciais ou dados pessoais reais.

## Situação atual

A base técnica da `laje-api` já possui runtime Express, configuração validada, camada PostgreSQL, healthchecks, quality gate, baseline PostgreSQL 17, arquitetura AWS documentada, containerização e base OpenAPI 3.1 com convenções HTTP. Os contratos dos fluxos de negócio e os módulos funcionais continuam sendo migrados nas tarefas subsequentes.
