# Healthchecks da `laje-api`

A LAJE-109 adiciona endpoints de saúde separados para a aplicação e para a dependência PostgreSQL. Essa separação permite que a infraestrutura diferencie disponibilidade do processo de disponibilidade do banco.

## `GET /api/v1/health`

Healthcheck da aplicação. Não consulta o PostgreSQL.

Resposta saudável (`200`):

```json
{
  "service": "laje-api",
  "status": "ok"
}
```

Esse endpoint é apropriado para liveness checks porque uma indisponibilidade temporária do banco não faz o processo HTTP ser tratado automaticamente como morto.

## `GET /api/v1/health/database`

Executa a verificação leve de conectividade fornecida pela camada PostgreSQL (`SELECT 1`).

Resposta disponível (`200`):

```json
{
  "database": "reachable",
  "status": "ok"
}
```

Resposta indisponível (`503`):

```json
{
  "database": "unreachable",
  "status": "unavailable"
}
```

O endpoint não retorna a exceção do driver, `DATABASE_URL`, hostname, usuário, credenciais ou outros detalhes internos de conexão.

## Uso futuro na AWS

Na etapa de containerização e deploy, o healthcheck da aplicação pode ser usado para liveness do container/serviço. A verificação de banco pode compor readiness ou diagnóstico operacional quando for necessário confirmar a dependência do Amazon RDS.

O RDS de staging permanece privado. Nenhum healthcheck exige tornar o banco acessível publicamente.
