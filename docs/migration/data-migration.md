# Migração de dados da LAJE-88

## Objetivo

Migrar os dados do schema `public` do Supabase para um RDS PostgreSQL 17 sem versionar dumps de produção nem expor dados pessoais em logs, GitHub, Jira ou saída de terminal.

## Pré-requisitos

- O RDS de destino possui o baseline `infra/database/baseline/schema.sql` e as migrations incrementais aplicadas por `scripts/apply-rds-baseline.sh` em um banco vazio.
- A execução ocorre em um ambiente temporário autorizado dentro da VPC que alcança a origem e o RDS privado por TLS.
- As URLs de conexão chegam ao processo por Secrets Manager ou outro mecanismo autorizado, sem serem salvas em `.env`, argumentos de processo, shell history ou arquivos versionados.
- O fluxo de corte só inicia depois dos gates LAJE-33, LAJE-37 e LAJE-89.

## Interfaces dos scripts

| Script                    | Entrada                                           | Efeito                                                                                                                                           |
| ------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `migration:export-schema` | `MIGRATION_SOURCE_DATABASE_URL`                   | Emite somente o SHA-256 do schema `public`.                                                                                                      |
| `migration:export-data`   | origem e `MIGRATION_EXECUTION_CONTEXT=controlled` | Emite um stream `pg_dump` e recusa terminal interativo.                                                                                          |
| `migration:import-data`   | destino, stream no stdin e autorização de escrita | Importa o stream em transação e deixa contas administrativas em primeiro acesso.                                                                 |
| `migration:sync-data`     | origem, destino, autorização e orçamento de storage | Mede o volume, bloqueia projeções acima do orçamento, limpa o destino, transfere apenas `public` por pipe e deixa contas administrativas em primeiro acesso. |
| `migration:verify-parity` | origem e destino                                  | Compara estrutura, contagens, hashes de PK e dos dados de cada tabela; valida reservas por contagem, IDs, campos, status e FKs sem retornar PII. |

As conexões são configuradas por `MIGRATION_SOURCE_DATABASE_URL` e `MIGRATION_DESTINATION_DATABASE_URL`. Quando necessário, os caminhos de CA podem ser fornecidos por `MIGRATION_SOURCE_SSL_ROOT_CERT` e `MIGRATION_DESTINATION_SSL_ROOT_CERT`.

## Transferência

Os scripts usam `pg_dump` e `psql` com credenciais passadas apenas por variáveis de ambiente do processo filho. `sync-data` conecta os dois comandos diretamente, portanto o dump não é criado em disco. Limpeza do destino, importação e preparação da autenticação dedicada são executadas em uma única transação. Se a exportação ou importação falhar, o destino mantém os dados anteriores.

A exportação de dados usa explicitamente `--schema=public`. Schemas transitórios ou internos, incluindo `championship_bracket_preview_private` e `laje_api_internal`, não são copiados. Isso evita duplicar no RDS histórico de jobs, slots, tentativas, filas ou bookkeeping de migrations; o RDS recria apenas a estrutura necessária por migrations versionadas e começa o estado transitório vazio.

Antes de limpar o destino, `sync-data` confere que origem e destino são bancos distintos, inclusive quando URLs diferentes chegam ao mesmo servidor PostgreSQL. O ensaio automatizado confirma que a tentativa de sincronizar um banco consigo mesmo preserva os registros.

Antes de iniciar o `pg_dump`, o script também mede `pg_database_size` e o tamanho total das relações de `public`. Os guardrails padrão são:

- `MIGRATION_MAX_SOURCE_PUBLIC_BYTES=268435456` (256 MiB);
- `MIGRATION_MAX_DESTINATION_DATABASE_BYTES=2147483648` (2 GiB).

A projeção do destino é deliberadamente conservadora: soma o tamanho atual do banco ao tamanho total de `public` na origem, embora o destino seja truncado antes da importação. Se a projeção exceder o orçamento, a sincronização termina antes de qualquer escrita. Para ampliar os valores é necessário definir explicitamente as variáveis no executor controlado, depois de conferir a capacidade real provisionada.

```bash
MIGRATION_EXECUTION_CONTEXT=controlled \
MIGRATION_ALLOW_DESTINATION_WRITE=true \
MIGRATION_SYNC_MODE=initial \
npm run migration:sync-data
```

O modo `final` exige também `MIGRATION_WRITES_PAUSED_AT`, registrado na janela de corte depois de bloquear novas gravações na origem.

As credenciais do Supabase Auth não são copiadas. Após cada importação, `admin_auth_accounts` e `admin_auth_sessions` ficam vazias e os perfis administrativos ficam `PENDING`, preservando o primeiro acesso administrado pela `laje-api`.

A comparação estrutural cobre colunas, enums, constraints internas ao `public` e índices. As 15 FKs da origem que apontam para `auth.users` são excluídas porque o destino não usa Supabase Auth. As duas tabelas de autenticação dedicada existem somente no destino e também ficam fora da comparação com a origem. O checksum de linhas de `admin_user_profiles` ignora `password_status` e `updated_at`, alterados de forma deliberada durante a preparação do primeiro acesso.

O ensaio automatizado no CI usa PostgreSQL 17 e 39 solicitações sintéticas. Ele executa sincronização e paridade ponta a ponta e confirma que uma falha de exportação não apaga os dados do destino. Esse ensaio não substitui a repetição em staging com acesso à origem real por um executor temporário dentro da VPC.

## Reserva de eventos e dados pessoais

A tabela `league_event_reservation_requests` é transferida dentro do mesmo pipe protegido. O verificador produz somente métricas agregadas: contagem, checksum de IDs, checksum dos campos, distribuição de status e quantidade de FKs inválidas. Na janela de corte, executar com `MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT=39`; a execução aceita a migração somente quando os 39 registros esperados, seus IDs, campos, relações de equipe e evento aprovado estiverem conciliados sem violação de FK.

## Limites

`sync-data` é uma operação destrutiva no destino e só deve ser executado contra banco de ensaio ou produção antes de o RDS receber tráfego de escrita. Ele não realiza deploy, troca `VITE_API_URL`, cria recursos AWS nem altera o Supabase.

Não há replicação contínua nem dual-write entre os dois bancos. Fora das janelas explícitas de `initial` e `final`, o Supabase não recebe cópias de volta e o RDS não recebe novas cópias automáticas. Essa decisão reduz custo, armazenamento duplicado e risco de divergência durante a coexistência.
