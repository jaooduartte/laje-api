# LAJE API

API dedicada da Liga das Atléticas de Joinville (LAJE), responsável por centralizar regras de negócio, autenticação, autorização, persistência e contratos HTTP do ambiente web `laje-tcc`.

O projeto Vercel `laje` continua sendo a produção operacional permanente da LAJE e usa Supabase. Esta API atende o deployment separado `laje-tcc`, do TCC/Portfólio; não altera nem substitui o backend Supabase de `laje`.

## Arquitetura do ambiente TCC

```text
Frontend React/Vite (Vercel: laje-tcc)
        |
        | HTTPS / REST
        v
API Gateway HTTP API
        |
        v
VPC Link -> ALB interno
        |
        v
LAJE API (Node.js + Express em Amazon ECS/AWS Fargate)
        |
        v
Amazon RDS PostgreSQL 17: laje-staging-postgres
```

`laje-staging-postgres` é o único RDS AWS selecionado para a entrega TCC. O prefixo `staging` é parte dos nomes existentes e não indica requisito de um segundo banco. O frontend publicado e a API local conectada pelo túnel SSM usam essa mesma instância. As contas sintéticas dos testes de fluxo são criadas apenas durante testes apontados para o banco `laje_priority_flows`; elas não são contas de homologação provisionadas no RDS publicado.

Arquitetura e evidências atuais estão em [docs/architecture.md](docs/architecture.md); publicação em [docs/deployment.md](docs/deployment.md); operação AWS em [docs/staging-aws.md](docs/staging-aws.md); e decisão formal em [docs/adr/0001-arquitetura-operacional-final.md](docs/adr/0001-arquitetura-operacional-final.md).

## Ambiente documentado

<!-- prettier-ignore -->
| Componente | Configuração |
| --- | --- |
| Frontend | Projeto Vercel `laje-tcc`, React/Vite |
| API pública | API Gateway HTTP API → VPC Link → ALB interno → ECS/Fargate |
| API | `laje-api` em Node.js + Express |
| Banco | Único RDS selecionado para o TCC: `laje-staging-postgres`, PostgreSQL 17, privado |
| Região | AWS `sa-east-1` |
| Desenvolvimento local | API local pelo túnel SSM para o mesmo RDS; CI usa PostgreSQL efêmero |

No frontend, `VITE_API_URL` aponta para a API do TCC. No backend local, use `.env` e o túnel SSM; no ECS, os parâmetros e segredos são injetados em runtime pelo Secrets Manager. Não versione credenciais reais.

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
- AWS CLI, Session Manager Plugin e sessão AWS com as permissões necessárias para executar o fluxo local via SSM;
- acesso ao RDS privado `laje-staging-postgres` pelo fluxo local documentado.

Não existe requisito de manter um PostgreSQL local permanente nem um `docker-compose` de banco. Em CI, o PostgreSQL 17 é efêmero. O desenvolvimento local da API usa o RDS privado pelo túnel SSM; o banco não deve ser tornado público para facilitar a execução.

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

`DATABASE_URL` continua sendo a forma recomendada para desenvolvimento e CI. Em runtime AWS, ela pode ser substituída por `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_PORT` e `DATABASE_SSLMODE`; os componentes obrigatórios devem estar presentes. O ECS injeta usuário e senha diretamente do Secrets Manager. Credenciais reais, tokens e valores do AWS Secrets Manager nunca devem ser adicionados ao repositório, ao README ou à imagem Docker.

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

O baseline contém a estrutura PostgreSQL necessária à API, sem dados do ambiente. Detalhes estão em [docs/migration/database-baseline.md](docs/migration/database-baseline.md).

## Executar a API compilada

Compile e inicie a API HTTP com os comandos abaixo:

```bash
npm run build
npm start
```

## Executar a API local com o RDS selecionado para o TCC

Configure a conexão PostgreSQL no `.env` para usar o host `127.0.0.1`, a porta `15432` e TLS. Você pode usar `DATABASE_URL` ou as variáveis `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USER`, `DATABASE_PASSWORD` e `DATABASE_SSLMODE`.

```bash
npm run dev:aws
```

O `npm run dev:aws` confere a conta AWS configurada, inicia os recursos necessários ao fluxo local e abre o túnel SSM em `127.0.0.1:15432`. Mantenha esse processo em execução. Em outro terminal, execute:

```bash
npm run dev
```

Ao terminar, pare `npm run dev` e encerre o processo de `npm run dev:aws` com `Ctrl+C` para fechar a sessão local.

No startup, a aplicação local valida a conexão PostgreSQL antes de abrir a porta HTTP. Se `DATABASE_URL` estiver ausente ou o banco estiver inacessível, a inicialização deve falhar em vez de disponibilizar uma API parcialmente funcional.

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
| `npm start` | Inicia a API compilada em `dist/server.js` |
| `npm run dev:aws` | Inicia os recursos necessários e abre o túnel SSM local |
| `npm run aws:on -- --allow-scheduled-shutdown` | Inicia os recursos para validar a parada automática sem criar override manual |
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

Os documentos técnicos descrevem os contratos atuais da API, a estrutura PostgreSQL e o histórico de evolução até o ambiente TCC:

- [Convenções HTTP](docs/api-conventions.md): formato de contratos, status codes, paginação, filtros, versionamento e autenticação futura;
- [Inventário de migração](docs/migration/supabase-inventory.md): referência histórica para a evolução do schema;
- [Baseline PostgreSQL](docs/migration/database-baseline.md): estrutura reproduzível para PostgreSQL 17;
- [Estratégia de migração](docs/migration/migration-strategy.md): fases, coexistência, cutover e responsabilidades;
- [Acesso PostgreSQL](docs/database-access.md): contratos da camada de persistência e requisitos de conexão;
- [Healthchecks](docs/healthchecks.md): semântica dos endpoints operacionais;
- [Ambiente AWS do TCC](docs/staging-aws.md): topologia, operação e evidências E2E;
- [CI/CD e deploy](docs/deployment.md): publicação manual, variáveis, segurança e validações;
- [Workloads operacionais AWS](docs/operational-workloads.md): SQS/DLQ, EventBridge, e-mail, calendário e observabilidade da LAJE-126;
- [Arquitetura operacional](docs/architecture.md): arquitetura implantada Vercel + AWS + RDS;
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
- `LAJE-127`: criação do RDS PostgreSQL que compõe o ambiente AWS atual;
- `LAJE-131`: containerização para execução/deploy AWS;
- `LAJE-136`: publicação e validação E2E dos workloads AWS;
- `LAJE-33`: CI/CD final entre frontend Vercel e backend AWS;
- `LAJE-142`: habilitação futura do deploy automático após merge em `main`, adiada para o momento do cutover;
- `LAJE-37`: documentação do deploy final.

## Regras de segurança e evolução

- não versionar `.env`, credenciais, tokens, chaves de serviço ou dumps produtivos;
- manter o RDS privado;
- usar AWS Secrets Manager/IAM para secrets e permissões no ambiente AWS;
- não alterar retroativamente o baseline consolidado: mudanças futuras de schema devem ser novas migrations em `infra/database/migrations/`;
- não executar migrations, alterações remotas de dados ou mudanças de infraestrutura sem autorização específica;
- não reintroduzir acesso direto do frontend ao banco no estado final;
- não publicar exemplos OpenAPI contendo tokens, credenciais ou dados pessoais reais.

## Situação atual

A `laje-api` tem runtime Express, acesso PostgreSQL, healthchecks, módulos de autenticação, campeonatos, jogos, classificação, chaveamento, eventos, auditoria e workloads operacionais, além de baseline PostgreSQL 17, OpenAPI 3.1, CI e deploy AWS manual. A cobertura de cada fluxo do frontend deve ser conferida nos contratos `/api/v1` e no código; o README do frontend registra operações administrativas que ainda não foram encaminhadas pela API.
