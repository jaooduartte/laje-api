# Containerização da laje-api

## Objetivo

A `laje-api` é empacotada em uma imagem Docker reproduzível para execução local, CI e futuro deploy em Amazon ECS/AWS Fargate. O container não inclui PostgreSQL local nem qualquer segredo de ambiente.

Arquitetura alvo:

```text
Frontend LAJE (Vercel - exceção aprovada para o projeto)
        ↓ HTTPS
Application Load Balancer (AWS)
        ↓
laje-api (ECS/Fargate)
        ↓
Amazon RDS for PostgreSQL 17
```

## Build

A imagem usa Node.js 22 e `Dockerfile` multi-stage. A etapa de build instala as dependências completas e gera `dist/`; a imagem final instala somente dependências de produção e executa diretamente `node dist/server.js`.

```bash
docker build -t laje-api:local .
```

A imagem final executa com o usuário `node`, sem privilégios de root.

## Configuração

Toda configuração é fornecida em runtime por variáveis de ambiente ou mecanismos de secrets. Nenhuma credencial é copiada para a imagem.

Variáveis mínimas:

```text
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://<usuario>:<senha>@<host>:5432/<database>?sslmode=require
CORS_ORIGINS=https://<frontend-publico>
```

As opções de pool e timeout permanecem configuráveis por:

```text
DATABASE_POOL_MAX
DATABASE_IDLE_TIMEOUT_SECONDS
DATABASE_CONNECT_TIMEOUT_SECONDS
DATABASE_SHUTDOWN_TIMEOUT_SECONDS
```

A aplicação aceita a troca de ambiente PostgreSQL exclusivamente pela `DATABASE_URL`, portanto o mesmo artefato pode apontar para integração/staging ou produção sem alteração de código.

## Execução local com PostgreSQL externo

O fluxo oficial não exige um PostgreSQL local persistente via Docker Compose. Para executar o container, informe uma instância PostgreSQL acessível ao host/container:

```bash
docker run --rm \
  --name laje-api \
  -p 3000:3000 \
  -e NODE_ENV=production \
  -e PORT=3000 \
  -e DATABASE_URL='postgresql://<usuario>:<senha>@<host>:5432/<database>?sslmode=require' \
  -e CORS_ORIGINS='https://<frontend-publico>' \
  laje-api:local
```

Não armazene valores reais de `DATABASE_URL`, tokens ou credenciais em comandos versionados, Dockerfile, README, arquivos `.env` commitados ou argumentos de build.

## Healthcheck

A imagem contém um `HEALTHCHECK` que consulta:

```text
GET /api/v1/health
```

Esse endpoint mede a saúde do processo HTTP e não depende do banco. A conectividade PostgreSQL pode ser verificada separadamente em:

```text
GET /api/v1/health/database
```

A separação permite utilizar o primeiro endpoint como liveness e o segundo como diagnóstico/readiness conforme a configuração definitiva no ECS/Fargate.

## Integração AWS

No ambiente de staging já existe um Amazon RDS for PostgreSQL 17 privado. O banco deve permanecer não público; a `laje-api` deverá acessá-lo a partir de workloads autorizados dentro da VPC.

Para ECS/Fargate, os valores sensíveis devem ser injetados em runtime por AWS Secrets Manager/ECS task definition. O segredo gerenciado automaticamente pelo RDS contém os campos de credencial do banco, mas a aplicação atualmente recebe uma única `DATABASE_URL`. A configuração de deploy deve, portanto, fornecer essa variável de forma segura — por exemplo, por um secret específico da aplicação ou por mecanismo de inicialização que componha a URL sem persistir credenciais na imagem.

Não exponha o RDS publicamente para simplificar o deploy.

## CI

O pipeline GitHub Actions valida:

- build TypeScript e testes existentes;
- baseline PostgreSQL 17;
- integração PostgreSQL 17;
- `docker build` da imagem final;
- inicialização real da imagem contra um PostgreSQL 17 efêmero de CI;
- respostas dos endpoints `/api/v1/health` e `/api/v1/health/database`;
- execução do processo como usuário não-root.

O PostgreSQL efêmero usado no CI existe somente durante o job e não é requisito do desenvolvimento ou do ambiente AWS.

## Segurança

- a imagem não contém `.env` nem segredos;
- a etapa final contém apenas dependências de produção e artefatos compilados;
- o processo executa como usuário não-root;
- o RDS permanece privado;
- credenciais devem ser fornecidas por secrets em runtime;
- o container não depende de deploy manual via SSH/FTP.
