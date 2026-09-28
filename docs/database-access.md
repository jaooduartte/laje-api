# Acesso PostgreSQL da `laje-api`

## Objetivo

A camada implementada na LAJE-107 estabelece o acesso ao PostgreSQL sem migrar regras de negócio. Ela prepara a `laje-api` para consumir o Amazon RDS PostgreSQL 17 provisionado na LAJE-127 e mantém os módulos de domínio desacoplados do driver PostgreSQL.

Fluxo da aplicação:

```text
módulo de domínio
    |
    v
Repository
    |
    v
DatabaseQueryExecutor
    |
    v
DatabaseClient
    |
    v
PostgresAdapter / pool
    |
    v
PostgreSQL 17
```

## Componentes

- `src/database/types.ts`: contratos mínimos de consulta, conexão e transação.
- `src/database/client.ts`: fachada da aplicação para consultas, transações, teste de conexão e encerramento do pool.
- `src/database/postgres-adapter.ts`: implementação do adapter usando `postgres` (Postgres.js) e pool de conexões.
- `src/database/transaction.ts`: fornece um executor limitado à conexão reservada pela transação.
- `src/database/repository.ts`: classe base para repositories que recebem um `DatabaseQueryExecutor` por injeção.
- `src/database/index.ts`: composition root da conexão PostgreSQL.

Repositories de domínio não devem importar o driver `postgres`, criar conexões próprias ou depender de uma conexão global bruta. O acesso deve ocorrer pelo executor recebido no construtor, permitindo reutilizar o mesmo repository tanto com o pool normal quanto dentro de uma transação.

## Configuração

A aplicação usa as seguintes variáveis:

| Variável | Padrão | Finalidade |
| --- | ---: | --- |
| `DATABASE_URL` | obrigatório | URI PostgreSQL completa. |
| `DATABASE_POOL_MAX` | `10` | Número máximo de conexões abertas pelo processo da API. |
| `DATABASE_IDLE_TIMEOUT_SECONDS` | `20` | Tempo máximo de ociosidade antes de liberar uma conexão. |
| `DATABASE_CONNECT_TIMEOUT_SECONDS` | `10` | Limite para estabelecimento de uma nova conexão. |
| `DATABASE_SHUTDOWN_TIMEOUT_SECONDS` | `5` | Janela de encerramento gracioso do pool. |

Exemplo local:

```text
DATABASE_URL=postgresql://laje:laje@localhost:5432/laje?sslmode=disable
```

Nenhuma credencial real deve ser versionada. Em AWS, a credencial deve permanecer no AWS Secrets Manager e ser disponibilizada à task da API em runtime.

## RDS de staging

A infraestrutura entregue pela LAJE-127 possui um RDS PostgreSQL 17 privado em `sa-east-1`, banco lógico `laje_staging` e endpoint privado:

```text
laje-staging-postgres.c7s8g84qonz5.sa-east-1.rds.amazonaws.com:5432
```

A instância exige SSL (`rds.force_ssl=1`) e o Security Group do banco aceita `5432` somente da camada de aplicação autorizada. Portanto, testes contra o RDS real devem partir da rede privada AWS prevista para a `laje-api`; o endpoint não deve ser tornado público para testes locais.

A URI do ambiente AWS deve habilitar TLS, por exemplo usando `sslmode=require`. Sempre que a cadeia de certificados utilizada pelo runtime estiver configurada para validar a CA do RDS, deve-se preferir validação equivalente a `sslmode=verify-full`, conforme a arquitetura do projeto.

## Lifecycle

No startup, `server.ts` executa uma consulta leve (`SELECT 1`) antes de abrir a porta HTTP. Se o PostgreSQL não estiver acessível, a API falha na inicialização em vez de iniciar parcialmente funcional.

Em `SIGINT` ou `SIGTERM`, a API:

1. interrompe o recebimento de novas conexões HTTP;
2. aguarda o encerramento do servidor HTTP;
3. encerra o pool PostgreSQL dentro do timeout configurado.

Esse comportamento prepara a aplicação para o lifecycle de containers no ECS/Fargate.

## Transações

Use `database.transaction(...)` quando uma operação precisar ser atômica:

```ts
await database.transaction(async (transaction) => {
  await transaction.query("UPDATE ...", []);
  await transaction.query("INSERT ...", []);
});
```

O executor recebido no callback está associado à conexão reservada para a transação. Repositories que recebem `DatabaseQueryExecutor` podem ser instanciados com esse executor para preservar a atomicidade sem conhecer detalhes do driver.

## Testes

Os testes unitários cobrem sucesso e falha de conexão, delegação de transações, encerramento do pool e injeção do executor nos repositories.

A integração real com PostgreSQL 17 é validada no CI usando um service container:

```bash
npm run test:integration
```

A conexão ao RDS real não é executada no CI público, pois o banco é privado e suas credenciais ficam fora do repositório. Essa validação deve ocorrer quando a task/container da API estiver conectada à VPC, etapa que será materializada nas tarefas seguintes da infraestrutura AWS.

## Fora do escopo da LAJE-107

- migração de queries/regras de negócio do Supabase;
- importação/cutover dos dados;
- endpoint de healthcheck HTTP (LAJE-109);
- container/deploy definitivo da API na AWS (LAJE-131).
