# LAJE-86 — Validação do núcleo esportivo

Este documento registra o estado de validação da tarefa `LAJE-86` — migração de campeonatos, jogos, standings e bracket para a `laje-api`.

## Escopo da validação

A `LAJE-86` considera como núcleo esportivo:

- campeonatos e temporadas;
- jogos, placar e estados operacionais;
- standings/classificação;
- bracket/mata-mata;
- consumo desses contratos pelo frontend administrativo e público.

## Contratos HTTP verificados

Os módulos implementados na `laje-api` expõem contratos versionados sob `/api/v1`.

### Campeonatos e temporadas

- `GET /championships`
- `POST /championships`
- `GET /championships/:championshipId`
- `PATCH /championships/:championshipId`
- `GET /championships/:championshipId/seasons/:seasonYear`
- `PUT /championships/:championshipId/seasons/:seasonYear`
- `GET /championships/:championshipId/calendar`

### Jogos

- `GET /matches`
- `GET /matches/:matchId`
- `POST /matches/:matchId/start`
- `PATCH /matches/:matchId/scoreboard`
- `POST /matches/:matchId/finish`

O contrato de finalização contempla os estados de W.O. utilizados pelo domínio.

### Standings

Os contratos de standings estão montados sob:

- `/championships/:championshipId/standings`

### Bracket

Os contratos de bracket estão montados sob:

- `/championships/:championshipId/bracket`

A especificação OpenAPI 3.1 e a documentação de desenvolvimento da API continuam sendo a referência formal dos contratos HTTP.

## Frontend

A branch `LAJE-86` do repositório `laje` já possui uma camada dedicada em `src/integrations/laje-api/sports-core.ts` e utiliza `VITE_API_URL` para selecionar o backend da arquitetura alvo.

Já existem caminhos dedicados para:

- listagem e leitura de campeonatos;
- atualização de campeonato;
- leitura de temporada;
- listagem e leitura de jogos;
- início de jogo;
- atualização de scoreboard;
- finalização de jogo;
- leitura de standings;
- leitura de bracket.

Durante a migração, o fallback para Supabase é mantido somente para preservar a produção atual enquanto o cutover não ocorre.

## Pendência funcional identificada

A validação de código encontrou operações administrativas do núcleo que ainda escrevem diretamente no Supabase em componentes legados, principalmente no controle operacional de partidas e em ações de ciclo de campeonato.

Essas operações precisam ser direcionadas para os contratos da `laje-api` quando `VITE_API_URL` estiver configurada, mantendo o caminho Supabase apenas como fallback do ambiente legado. A tarefa não deve ser considerada concluída enquanto essas escritas diretas forem o caminho principal no ambiente dedicado.

## Ambiente AWS verificado em 2026-09-29

Foi confirmado no ambiente AWS de staging:

- Amazon RDS for PostgreSQL disponível;
- PostgreSQL 17;
- instância privada (`PubliclyAccessible = false`);
- criptografia de storage habilitada;
- segredo gerenciado pelo AWS Secrets Manager;
- logs PostgreSQL disponíveis no CloudWatch.

Também foi confirmado que, no momento desta validação, não existe workload da `laje-api` ativo em ECS/Fargate, ECR, ALB, Lambda ou EC2 na região de staging consultada. Portanto, o teste E2E `Vercel/frontend -> laje-api AWS -> RDS` ainda não pode ser executado contra um endpoint AWS publicado.

O deploy da API é tratado pelo fluxo de CI/CD/infraestrutura do projeto e não deve ser confundido com o provisionamento do RDS já concluído.

## Quality Gate

As duas PRs da `LAJE-86` devem permanecer sem merge até a conclusão desta validação. Os workflows atuais dos dois repositórios devem continuar aprovando, no mínimo:

- typecheck;
- lint;
- formatação, quando aplicável;
- testes;
- build.

## Checklist para fechamento

A tarefa pode ser movida para concluída quando todos os itens abaixo estiverem comprovados:

- [x] contratos de campeonatos/temporadas implementados na API;
- [x] contratos de jogos implementados na API;
- [x] contratos de standings implementados na API;
- [x] contratos de bracket implementados na API;
- [x] frontend possui camada de integração com `laje-api`;
- [x] RDS PostgreSQL de staging está disponível e privado;
- [ ] escritas administrativas de partidas usam `laje-api` quando `VITE_API_URL` está configurada;
- [ ] ações administrativas de campeonato/temporada usam `laje-api` quando `VITE_API_URL` está configurada;
- [ ] `laje-api` está publicada no ambiente AWS de integração/staging;
- [ ] frontend de validação aponta `VITE_API_URL` para o endpoint AWS;
- [ ] fluxo E2E de campeonato, partida, scoreboard/W.O., standings e bracket validado no admin;
- [ ] consultas públicas equivalentes validadas contra a API;
- [ ] Quality Gate das duas PRs continua verde no HEAD final.

## Relação com tarefas adjacentes

- `LAJE-88` trata migração definitiva de schema/dados e cutover do banco;
- `LAJE-89` trata a substituição de Realtime dependente de Supabase;
- `LAJE-33` trata o CI/CD final e o deploy controlado do backend na AWS;
- `LAJE-37` trata a documentação final de deploy.

Essas tarefas não devem ampliar artificialmente o escopo funcional da `LAJE-86`, mas o ambiente AWS publicado é necessário para produzir a evidência E2E de integração antes do fechamento definitivo.