# Migração de dados da LAJE-88

## Objetivo

Migrar os dados do schema `public` do Supabase para um RDS PostgreSQL 17 sem versionar dumps de produção nem expor dados pessoais em logs, GitHub, Jira ou saída de terminal.

## Pré-requisitos

- O RDS de destino possui o baseline `infra/database/baseline/schema.sql` e a migration `20260928190000_create_admin_auth.sql` aplicados.
- A execução ocorre em um ambiente temporário autorizado dentro da VPC que alcança a origem e o RDS privado por TLS.
- As URLs de conexão chegam ao processo por Secrets Manager ou outro mecanismo autorizado, sem serem salvas em `.env`, argumentos de processo, shell history ou arquivos versionados.
- O fluxo de corte só inicia depois dos gates LAJE-33, LAJE-37 e LAJE-89.

## Interfaces dos scripts

| Script                    | Entrada                                           | Efeito                                                                                                               |
| ------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `migration:export-schema` | `MIGRATION_SOURCE_DATABASE_URL`                   | Emite somente o SHA-256 do schema `public`.                                                                          |
| `migration:export-data`   | origem e `MIGRATION_EXECUTION_CONTEXT=controlled` | Emite um stream `pg_dump` e recusa terminal interativo.                                                              |
| `migration:import-data`   | destino, stream no stdin e autorização de escrita | Importa o stream em transação e deixa contas administrativas em primeiro acesso.                                     |
| `migration:sync-data`     | origem, destino e autorização de escrita          | Limpa o destino, transfere dados por pipe e deixa contas administrativas em primeiro acesso.                         |
| `migration:verify-parity` | origem e destino                                  | Compara tabelas por contagem e hash de PK; valida reservas por contagem, IDs, campos, status e FKs sem retornar PII. |

As conexões são configuradas por `MIGRATION_SOURCE_DATABASE_URL` e `MIGRATION_DESTINATION_DATABASE_URL`. Quando necessário, os caminhos de CA podem ser fornecidos por `MIGRATION_SOURCE_SSL_ROOT_CERT` e `MIGRATION_DESTINATION_SSL_ROOT_CERT`.

## Transferência

Os scripts usam `pg_dump` e `psql` com credenciais passadas apenas por variáveis de ambiente do processo filho. `sync-data` conecta os dois comandos diretamente, portanto o dump não é criado em disco. O destino é truncado antes da cópia para impedir mistura de registros entre ensaios.

```bash
MIGRATION_EXECUTION_CONTEXT=controlled \
MIGRATION_ALLOW_DESTINATION_WRITE=true \
MIGRATION_SYNC_MODE=initial \
npm run migration:sync-data
```

O modo `final` exige também `MIGRATION_WRITES_PAUSED_AT`, registrado na janela de corte depois de bloquear novas gravações na origem.

As credenciais do Supabase Auth não são copiadas. Após cada importação, `admin_auth_accounts` e `admin_auth_sessions` ficam vazias e os perfis administrativos ficam `PENDING`, preservando o primeiro acesso administrado pela `laje-api`.

## Reserva de eventos e dados pessoais

A tabela `league_event_reservation_requests` é transferida dentro do mesmo pipe protegido. O verificador produz somente métricas agregadas: contagem, checksum de IDs, checksum dos campos, distribuição de status e quantidade de FKs inválidas. Na janela de corte, executar com `MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT=39`; a execução aceita a migração somente quando os 39 registros esperados, seus IDs, campos, relações de equipe e evento aprovado estiverem conciliados sem violação de FK.

## Limites

`sync-data` é uma operação destrutiva no destino e só deve ser executado contra banco de ensaio ou produção antes de o RDS receber tráfego de escrita. Ele não realiza deploy, troca `VITE_API_URL`, cria recursos AWS nem altera o Supabase.
