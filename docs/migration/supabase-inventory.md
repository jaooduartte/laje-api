# Inventário do Supabase para migração

Data da coleta: 2026-09-27

> Rastreabilidade: este inventário foi preparado originalmente na LAJE-111 e na PR #6. A PR foi fechada sem merge e o arquivo permaneceu vazio na `main`. A LAJE-114 recupera o conteúdo para restaurar o artefato documental esperado e permitir que a estratégia de migração referencie um inventário efetivamente versionado.

## Objetivo e limite desta entrega

Este documento registra o backend Supabase ativo antes da migração gradual para a API dedicada. A fonte é o catálogo do projeto `laje` (`cugqidtapnqvonbdbbdf`), em PostgreSQL 17.6, cruzado com as migrations e Edge Functions versionadas no repositório `laje`.

Esta entrega não cria recursos na AWS, não exporta dados e não altera o Supabase. O alvo arquitetural aprovado é Amazon RDS for PostgreSQL 17, privado e acessível somente pela `laje-api`.

## Fotografia do catálogo

<!-- prettier-ignore -->
| Objeto | Quantidade | Destino |
| --- | ---: | --- |
| Tabelas no schema `public` | 67 | Copiar para o PostgreSQL no RDS |
| Rotinas no schema `public` | 330 | Separar entre PostgreSQL e Node/Express por responsabilidade |
| Triggers não internos | 75 | Manter somente as invariantes de dados no PostgreSQL |
| Policies RLS | 154 | Migrar autorização para a API |
| Rotinas com `auth.uid()` | 54 | Migrar para Node/Express, com identidade autenticada da API |
| Edge Functions ativas | 3 | Migrar para módulos e jobs da API |

Todas as tabelas públicas estão com RLS habilitado. Esse modelo não será copiado para o RDS como mecanismo de acesso direto do frontend: a `laje-api` será a única camada de acesso e aplicará autenticação e autorização antes de executar operações no banco.

## Estrutura relacional a preservar

As tabelas, enums, chaves primárias e estrangeiras, constraints e índices pertencem ao baseline estrutural do PostgreSQL. A ordem abaixo organiza as 67 tabelas em domínios para as próximas tarefas; todas têm classificação **copiar para PostgreSQL**, com a ressalva de que referências a usuários do Supabase deverão apontar para a identidade administrada pela API.

<!-- prettier-ignore -->
| Domínio | Tabelas |
| --- | --- |
| Fundação esportiva | `sports`, `teams`, `championships`, `championship_sports`, `matches`, `standings`, `match_sets` |
| Administração e acesso | `user_roles`, `admin_profiles`, `admin_profile_permissions`, `admin_user_profiles`, `admin_action_logs`, `public_page_access_settings` |
| Eventos e reservas | `league_events`, `league_event_organizer_teams`, `league_event_reservation_requests`, `league_calendar_holidays` |
| Chaveamento e agenda | `championship_bracket_editions`, `championship_bracket_team_registrations`, `championship_bracket_team_modalities`, `championship_bracket_competitions`, `championship_bracket_groups`, `championship_bracket_group_teams`, `championship_bracket_days`, `championship_bracket_locations`, `championship_bracket_courts`, `championship_bracket_court_sports`, `championship_bracket_matches`, `championship_bracket_location_templates`, `championship_bracket_location_template_courts`, `championship_bracket_location_template_court_sports`, `championship_bracket_tie_break_resolutions`, `championship_bracket_tie_break_resolution_teams`, `championship_bracket_day_breaks`, `championship_bracket_location_sport_priorities`, `championship_bracket_knockout_court_priorities`, `championship_bracket_knockout_schedule_reservations`, `championship_knockout_result_corrections` |
| Premiações e disciplina | `championship_award_players`, `match_award_goal_scorers`, `championship_award_draw_results`, `match_yellow_card_players`, `match_red_card_players`, `match_blue_card_players`, `championship_competition_team_disqualifications`, `championship_walkover_penalty_settings`, `championship_walkover_penalty_counts` |
| Configuração pública | `public_link_sections`, `public_link_items`, `public_link_item_filters` |
| Temporada, individuais e classificação geral | `championship_season_settings`, `championship_season_division_movements`, `championship_season_sport_removals`, `championship_individual_events`, `championship_individual_event_entries`, `championship_individual_event_entry_members`, `championship_individual_team_standings`, `championship_individual_sessions`, `championship_overall_competition_placements`, `championship_overall_score_adjustments`, `championship_overall_tie_break_resolutions`, `championship_overall_tie_break_resolution_teams`, `championship_opening_ceremony_bonus_settings`, `championship_overall_position_point_settings`, `championship_interlaje_tie_break_resolutions`, `championship_interlaje_ranking_audits`, `championship_interlaje_individual_tie_break_resolutions` |

## Funções, triggers e autorização

O schema `public` possui 330 rotinas e 75 triggers. A migração não será um dump dessas definições: cada grupo abaixo tem um destino explícito.

<!-- prettier-ignore -->
| Grupo | Evidência | Destino |
| --- | --- | --- |
| Cálculos determinísticos, validações de integridade e projeções relacionais sem contexto de usuário | Rotinas e triggers sem dependência de Auth | Copiar para PostgreSQL quando a regra pertencer à integridade persistida |
| Autorização de painel, papéis e operações iniciadas por usuário | 54 rotinas usam `auth.uid()`; policies dependem de identidade e roles do Supabase | Migrar para serviços e middlewares Node/Express |
| Operações administrativas, geração de chaveamento, reprogramação e classificação | RPCs chamadas pelo frontend e regras de domínio extensas | Migrar para serviços da API, mantendo transações no PostgreSQL quando necessário |
| Auditoria por ator | Triggers e rotinas gravam o usuário autenticado do Supabase | Migrar para a API, passando o usuário autenticado como contexto explícito |
| Policies RLS | 154 policies, inclusive referências a `auth.uid()` | Substituir pela autorização centralizada na API; não expor o RDS ao frontend |

O inventário detalhado de cada rotina, trigger e policy será usado por domínio na tarefa de migração correspondente. Antes de mover qualquer domínio, a implementação deve consultar `pg_proc`, `pg_trigger`, `pg_policy`, enums, constraints e índices do projeto ativo e anexar o resultado à migration revisada. A classificação acima é a regra de decisão para todos os itens desses catálogos, não uma autorização para copiar funções acopladas ao Supabase.

## Dependências Supabase e substituições

<!-- prettier-ignore -->
| Dependência atual | Uso identificado | Destino |
| --- | --- | --- |
| Supabase Auth e `auth.uid()` | Identidade em RLS, RPCs e trilhas administrativas | Autenticação e autorização da `laje-api`; modelo de usuários próprio no PostgreSQL |
| `pgmq` | Fila `championship_bracket_preview` para processamento assíncrono | Amazon SQS e worker da API |
| `pg_cron` | Recuperação e limpeza do preview de chaveamento | Amazon EventBridge Scheduler acionando worker da API |
| Supabase Vault | Segredos acessados pelo banco | AWS Secrets Manager, acessado pela API e pela infraestrutura |
| `pgcrypto`, `uuid-ossp` | Utilitários PostgreSQL instalados | Validar disponibilidade e manter no RDS somente se usados pelo baseline |
| Supabase Realtime | Atualizações de interface | Substituir em tarefa própria; não faz parte do baseline do banco |

## Edge Functions

<!-- prettier-ignore -->
| Função | Dependências identificadas | Destino |
| --- | --- | --- |
| `send-reservation-email` | Brevo, `BREVO_API_KEY`, URLs e destinatários configurados por ambiente | Serviço de e-mail da `laje-api`; segredos no Secrets Manager |
| `process-championship-bracket-preview` | `SUPABASE_URL`, chave de serviço, RPC de processamento e header `Authorization` | Worker Node/Express acionado por SQS e EventBridge, com persistência no RDS |
| `calendar-subscription-feed` | `supabase-js`, chave de serviço, consultas e RPCs de calendário | Endpoint público da API consumindo PostgreSQL diretamente |

Nenhuma Edge Function exige `verify_jwt` no deploy atual. Essa configuração não será reproduzida: os endpoints da API deverão aplicar autenticação ou autorização conforme o contrato de cada fluxo.


### Estado da substituição — LAJE-126

A implementação AWS foi versionada mantendo coexistência segura com o ambiente legado:

- `pgmq championship_bracket_preview` -> SQS + DLQ, com worker da `laje-api`;
- `pg_cron */2 * * * *` -> EventBridge Scheduler enviando mensagem de manutenção à fila;
- `process-championship-bracket-preview` -> serviço/worker Node, persistência no RDS e contratos HTTP;
- `send-reservation-email` -> serviço Brevo da `laje-api`, com chave prevista no Secrets Manager;
- `calendar-subscription-feed` -> endpoint público da `laje-api` consultando PostgreSQL;
- falhas e backlog -> CloudWatch Logs + alarmes da fila/DLQ.

Os objetos Supabase permanecem disponíveis apenas durante a coexistência. A remoção física será feita somente depois do cutover da LAJE-139.

## Sequência de migração

1. Criar o baseline estrutural no RDS sem dados produtivos e validar as extensões estritamente necessárias.
2. Migrar autenticação, papéis e auditoria para a API antes de remover dependências de `auth.uid()`.
3. Migrar por domínio: fundação esportiva, administração, eventos, chaveamento, classificação e fluxos públicos.
4. Substituir jobs, filas, e-mail e atualizações em tempo real por componentes fora do banco.
5. Executar ensaio local e em staging; somente uma tarefa de cutover poderá tratar cópia de dados e alteração de tráfego.

## Critérios para as próximas migrations

- toda migration deve declarar o domínio, objetos de origem e a classificação aplicada neste inventário;
- funções e triggers copiados devem ser reproduzíveis em PostgreSQL 17 no RDS e ter teste de integração;
- regras que recebiam `auth.uid()` devem ter o usuário autenticado validado pela API antes da transação;
- nenhuma migration pode carregar chaves de serviço, dados produtivos ou conteúdo do Vault.
