# Baseline PostgreSQL — LAJE-112

## Objetivo

A LAJE-112 estabelece um baseline SQL reproduzível para recriar a estrutura de dados necessária da plataforma LAJE em um PostgreSQL 17 limpo, sem depender do Supabase para executar o bootstrap do banco.

O baseline foi extraído do estado estrutural do projeto Supabase `laje` (`cugqidtapnqvonbdbbdf`) em 27/09/2026, atualmente em PostgreSQL 17.6.

O arquivo de entrada oficial é:

```text
infra/database/baseline/schema.sql
```

Ele inclui os arquivos auxiliares da mesma pasta por meio de `psql`/`\ir`.

## Estrutura consolidada

O baseline reproduz:

- 37 tipos ENUM do schema `public`;
- 67 tabelas do schema `public`;
- tipos de coluna, `NULL`/`NOT NULL` e valores `DEFAULT`;
- 67 primary keys;
- 45 constraints `UNIQUE`;
- 91 constraints `CHECK`;
- 134 foreign keys internas (`public` -> `public`);
- 92 índices standalone;
- a função estrutural `public.coerce_division_for_index(team_division)`, necessária para recriar o índice de fila de jogos.

Não existem sequences explícitas no schema `public` deste snapshot. Os identificadores UUID usam `gen_random_uuid()`, disponível no PostgreSQL 17, portanto o baseline estrutural não exige a instalação de uma extensão não-core.

## Limite do baseline

Esta tarefa é exclusivamente estrutural. Não fazem parte da LAJE-112:

- dados de produção;
- schemas internos do Supabase;
- Supabase Auth;
- Supabase Storage;
- Supabase Realtime;
- RLS e policies específicas da plataforma atual;
- Edge Functions;
- jobs `pg_cron`;
- triggers e rotinas de regra de negócio que serão transferidos por domínio para a `laje-api`;
- provisionamento de infraestrutura AWS.

O banco de origem possui 149 foreign keys no schema `public`. Quinze delas apontam para `auth.users`. As colunas UUID correspondentes foram preservadas, mas essas 15 constraints não são criadas pelo baseline para evitar uma dependência estrutural do Supabase Auth. A modelagem definitiva desses vínculos faz parte da LAJE-85, que migra autenticação, autorização e auditoria administrativa.

As colunas afetadas são:

- `admin_action_logs.actor_user_id`;
- `admin_user_profiles.user_id`;
- `championship_bracket_editions.created_by`;
- `championship_bracket_editions.updated_by`;
- `championship_bracket_tie_break_resolutions.created_by`;
- `championship_competition_team_disqualifications.created_by`;
- `championship_interlaje_individual_tie_break_resolutions.resolved_by`;
- `championship_interlaje_tie_break_resolutions.resolved_by`;
- `championship_knockout_result_corrections.created_by`;
- `championship_overall_competition_placements.confirmed_by`;
- `championship_overall_score_adjustments.granted_by`;
- `championship_overall_tie_break_resolutions.created_by`;
- `championship_season_sport_removals.removed_by`;
- `public_page_access_settings.updated_by`;
- `user_roles.user_id`.

## Como executar

O baseline deve ser aplicado em um banco PostgreSQL 17 vazio.

```bash
psql "$DATABASE_URL" \
  --set ON_ERROR_STOP=1 \
  --file infra/database/baseline/schema.sql
```

Depois, execute a validação estrutural:

```bash
psql "$DATABASE_URL" \
  --set ON_ERROR_STOP=1 \
  --file infra/database/baseline/validate.sql
```

`schema.sql` executa tudo em uma transação. Se qualquer parte falhar, `ON_ERROR_STOP` interrompe o processo e a transação não é consolidada.

## Validação automática

`validate.sql` verifica os números esperados do snapshot e falha se houver divergência de tabelas, enums, constraints, foreign keys, índices, sequences ou da função estrutural necessária.

O GitHub Actions também executa o baseline contra um container oficial `postgres:17` a cada push e pull request. Isso garante que um banco vazio possa ser criado de forma reproduzível antes de a mudança ser integrada.

## AWS

O mesmo `schema.sql` é compatível com a arquitetura alvo em Amazon RDS for PostgreSQL 17. A LAJE-112 não provisiona RDS e não realiza cutover de produção.

A criação do banco AWS, exportação/importação dos dados, ensaio de migração, validação de integridade, cutover e rollback pertencem à LAJE-88.

Para uma migração PostgreSQL -> PostgreSQL deste porte, o caminho planejado permanece baseado nas ferramentas nativas `pg_dump`/`pg_restore` ou `psql`, mantendo schema e dados como artefatos separados.

## Evolução após o baseline

Após a consolidação deste baseline na `main`, ele passa a representar o ponto zero estrutural da nova arquitetura. Não devem ser feitas alterações retroativas para representar mudanças futuras do produto.

Toda alteração posterior de schema deve ser criada em um novo arquivo versionado dentro de:

```text
infra/database/migrations/
```

Esse padrão preserva rastreabilidade, reprodutibilidade e histórico arquitetural para o Portfólio/TCC.
