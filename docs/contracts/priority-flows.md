# Contratos dos três fluxos prioritários

## Objetivo e status

Este documento é a referência de contrato da LAJE-84 para os três fluxos de negócio obrigatórios do Portfólio Web App:

1. autenticação administrativa;
2. operação ao vivo de jogos;
3. consulta pública de campeonatos, classificação e calendário.

Os contratos abaixo estão **definidos, mas ainda não implementados**. A implementação pertence às tarefas de migração subsequentes, principalmente LAJE-85 e LAJE-86. Enquanto o cutover não ocorrer, o frontend de produção continua usando o backend atual do Supabase.

A especificação OpenAPI correspondente está em `src/openapi/openapi.document.ts`. Todos os endpoints desta entrega usam a extensão `x-implementation-status: planned` para impedir que a documentação seja interpretada como funcionalidade já entregue.

As regras gerais de versionamento, envelopes, erros, paginação, filtros e segurança permanecem em [docs/api-conventions.md](../api-conventions.md).

## Princípios do contrato

- base HTTP: `/api/v1`;
- payloads de negócio: JSON;
- respostas de negócio bem-sucedidas: `{ "data": ... }`, com `meta` quando houver paginação;
- erros: `{ "error": { "code", "message", "details?" } }`;
- parâmetros de query usam `camelCase`;
- DTOs da nova API usam `camelCase` e não expõem nomes de colunas ou joins do PostgreSQL;
- UUIDs são strings com `format: uuid`;
- datas usam `YYYY-MM-DD`; instantes usam ISO 8601;
- operações administrativas são autorizadas na API, nunca apenas no frontend;
- nenhum contrato expõe credenciais do PostgreSQL, chaves do Supabase ou dados internos de infraestrutura.

## 1. Fluxo de autenticação administrativa

### Estado atual a substituir

O frontend atual autentica diretamente no Supabase Auth, acompanha a sessão no navegador e consulta RPCs como `get_current_user_admin_context` e `can_access_admin_panel`. A arquitetura alvo move autenticação, autorização e contexto administrativo para a `laje-api`.

### Endpoints

| Método | Endpoint | Autenticação | Finalidade |
| --- | --- | --- | --- |
| `POST` | `/api/v1/auth/sessions` | pública | autenticar e criar sessão administrativa |
| `POST` | `/api/v1/auth/sessions/refresh` | refresh cookie | renovar access token |
| `DELETE` | `/api/v1/auth/sessions/current` | Bearer JWT | encerrar a sessão atual |
| `GET` | `/api/v1/auth/me` | Bearer JWT | obter identidade, perfil e permissões atuais |

### Login

Requisição:

```json
{
  "email": "operador@example.invalid",
  "password": "<senha>"
}
```

Resposta `200`:

```json
{
  "data": {
    "accessToken": "<jwt>",
    "tokenType": "Bearer",
    "expiresAt": "2026-09-28T18:00:00.000Z",
    "user": {
      "id": "00000000-0000-0000-0000-000000000000",
      "email": "operador@example.invalid",
      "role": "mesa",
      "profile": null,
      "permissions": [
        { "scope": "control", "level": "EDIT" },
        { "scope": "matches", "level": "VIEW" }
      ],
      "canAccessAdminPanel": true
    }
  }
}
```

A credencial de renovação não é devolvida no corpo. O contrato prevê cookie `laje_refresh_token` com `HttpOnly`, `Secure` e política `SameSite` compatível com a topologia frontend Vercel + API AWS. A implementação da LAJE-85 deve validar CORS com credenciais e definir expiração/rotação sem armazenar token de refresh em `localStorage`.

### Contexto administrativo

`GET /api/v1/auth/me` substitui a dependência do frontend em RPC de contexto. O DTO contém:

- identidade (`id`, `email`);
- `role`: `admin`, `eventos`, `mesa` ou `null` para perfil customizado;
- `profile`: `id` e `name` quando houver perfil customizado;
- `permissions`: lista de `{ scope, level }`;
- `level`: `NONE`, `VIEW` ou `EDIT`;
- `canAccessAdminPanel`: decisão efetiva calculada pelo backend.

Os scopes seguem as áreas existentes do painel: `bracket_setup`, `matches`, `control`, `individual_events`, `teams`, `sports`, `events`, `links`, `logs`, `users`, `account`, `standings`, `championship_status`, `settings`, `score_sheet_review`, `tie_breaks`, `championship_schedule` e `opening_ceremony_bonus`.

### Erros contratuais

| HTTP | `error.code` | Situação |
| --- | --- | --- |
| `401` | `INVALID_CREDENTIALS` | e-mail/senha não conferem |
| `401` | `SESSION_EXPIRED` | access/refresh token inválido ou expirado |
| `403` | `ADMIN_ACCESS_DENIED` | identidade válida sem acesso administrativo |
| `422` | `VALIDATION_ERROR` | payload semanticamente inválido |

A API não diferencia publicamente “e-mail inexistente” de “senha incorreta”.

## 2. Fluxo de operação ao vivo de jogos

### Estado atual a substituir

O frontend atual lê `matches` diretamente via Supabase, aplica filtros no cliente/PostgREST e executa updates administrativos diretamente na tabela. O contrato alvo centraliza leitura e comandos de estado/placar na `laje-api`.

### Endpoints

| Método | Endpoint | Autenticação | Finalidade |
| --- | --- | --- | --- |
| `GET` | `/api/v1/matches` | pública | listar jogos com filtros/paginação |
| `GET` | `/api/v1/matches/{matchId}` | pública | consultar um jogo |
| `POST` | `/api/v1/matches/{matchId}/start` | Bearer JWT + `control:EDIT` | iniciar jogo |
| `PATCH` | `/api/v1/matches/{matchId}/scoreboard` | Bearer JWT + `control:EDIT` | atualizar placar/cartões/estado corrente |
| `POST` | `/api/v1/matches/{matchId}/finish` | Bearer JWT + `control:EDIT` | encerrar jogo |

### Consulta de jogos

`GET /api/v1/matches` aceita:

- `championshipId`;
- `seasonYear`;
- `status` repetível: `SCHEDULED`, `LIVE`, `FINISHED`;
- `sportId`;
- `teamId`;
- `naipe`: `MASCULINO`, `FEMININO`, `MISTO`;
- `division`: `DIVISAO_PRINCIPAL`, `DIVISAO_ACESSO`;
- `location`;
- `courtName`;
- `page` e `pageSize`;
- `sort` e `order` conforme allowlist do endpoint.

A resposta usa `MatchDto`, com dados suficientes para páginas públicas e operação ao vivo sem replicar o formato de joins do Supabase. Equipes e modalidade são objetos aninhados, enquanto identificadores e campos de agenda permanecem explícitos.

### Iniciar jogo

`POST /api/v1/matches/{matchId}/start` é um comando de domínio. É válido apenas para jogo `SCHEDULED` e deve registrar o início efetivo no backend. Repetição contra um jogo já `LIVE` ou `FINISHED` retorna conflito, sem aplicar transição silenciosa.

Resposta `200`: `MatchDto` atualizado no envelope padrão.

### Atualizar placar

`PATCH /api/v1/matches/{matchId}/scoreboard` aceita somente campos previstos para o esporte/jogo. Base comum:

```json
{
  "homeScore": 2,
  "awayScore": 1,
  "currentSetHomeScore": null,
  "currentSetAwayScore": null,
  "homeYellowCards": 1,
  "awayYellowCards": 0,
  "homeRedCards": 0,
  "awayRedCards": 0,
  "homeBlueCards": 0,
  "awayBlueCards": 0,
  "homeTwoMinutePenalties": 0,
  "awayTwoMinutePenalties": 0,
  "homePenaltyScore": null,
  "awayPenaltyScore": null
}
```

Campos não aplicáveis podem ser omitidos. O backend é responsável por validar valores negativos, regras da modalidade e estado do jogo.

### Encerrar jogo

`POST /api/v1/matches/{matchId}/finish` finaliza um jogo `LIVE`. O payload pode informar o placar final e flags de walkover quando aplicáveis; a implementação deverá executar as regras de domínio e atualizações derivadas de classificação em transação controlada.

### Autorização

Comandos operacionais exigem Bearer JWT e permissão efetiva `control:EDIT`. A LAJE-85 implementará a identidade/autorização; a LAJE-86 implementará as regras de jogos. A interface pode ocultar botões, mas isso não substitui a autorização da API.

### Erros contratuais

| HTTP | `error.code` | Situação |
| --- | --- | --- |
| `401` | `SESSION_EXPIRED` | sessão ausente/inválida |
| `403` | `PERMISSION_DENIED` | usuário sem `control:EDIT` |
| `404` | `MATCH_NOT_FOUND` | jogo inexistente |
| `409` | `MATCH_STATE_CONFLICT` | transição incompatível com estado atual |
| `409` | `MATCH_UPDATE_CONFLICT` | conflito de atualização concorrente quando detectado |
| `422` | `VALIDATION_ERROR` | placar/payload incompatível com regras do jogo |

## 3. Fluxo público de campeonatos, classificação e calendário

### Estado atual a substituir

As telas públicas atuais consultam tabelas/RPCs do Supabase diretamente. O contrato alvo cria uma fachada HTTP pública, somente leitura, sobre os dados necessários às páginas de campeonatos, classificação e agenda.

### Endpoints

| Método | Endpoint | Autenticação | Finalidade |
| --- | --- | --- | --- |
| `GET` | `/api/v1/championships` | pública | listar campeonatos visíveis |
| `GET` | `/api/v1/championships/{championshipId}` | pública | consultar campeonato |
| `GET` | `/api/v1/championships/{championshipId}/standings` | pública | classificação por temporada/modalidade/naipe/divisão |
| `GET` | `/api/v1/championships/{championshipId}/calendar` | pública | agenda de jogos do campeonato |

### Campeonato

`ChampionshipDto` contém:

```json
{
  "id": "00000000-0000-0000-0000-000000000000",
  "code": "INTERLAJE",
  "name": "Interlaje",
  "status": "IN_PROGRESS",
  "currentSeasonYear": 2026,
  "usesDivisions": true,
  "defaultLocation": null
}
```

Status aceitos: `PLANNING`, `UPCOMING`, `REVIEW`, `IN_PROGRESS`, `FINISHED`.

### Classificação

`GET /standings` exige `seasonYear` e aceita `sportId`, `naipe`, `division`, `page` e `pageSize`.

Cada `StandingDto` inclui `position`, equipe, modalidade, escopo competitivo e métricas existentes: jogos, vitórias, empates, derrotas, gols, pontos, cartões, sets/rally points quando aplicáveis e campos de esporte individual quando necessários. O backend deve entregar a ordem oficial já resolvida; o frontend não deve recriar regras de desempate a partir de colunas cruas.

### Calendário

`GET /calendar` exige `seasonYear` e aceita `from`, `to`, `sportId`, `teamId`, `naipe`, `division`, `page` e `pageSize`.

A entrada de calendário usa `MatchDto`, preservando status e dados de agenda necessários para a página pública. `from` e `to` usam `YYYY-MM-DD` e são inclusivos. A API valida `from <= to`.

### Erros contratuais

| HTTP | `error.code` | Situação |
| --- | --- | --- |
| `404` | `CHAMPIONSHIP_NOT_FOUND` | campeonato inexistente/não consultável |
| `422` | `VALIDATION_ERROR` | filtros semanticamente inválidos |

Endpoints públicos nunca retornam informações administrativas, credenciais ou metadados internos de infraestrutura.

## Matriz de transição frontend -> API

| Fluxo | Dependência atual | Contrato alvo | Implementação |
| --- | --- | --- | --- |
| login/sessão | Supabase Auth no frontend | `/auth/sessions`, `/auth/sessions/refresh`, `/auth/sessions/current` | LAJE-85 |
| contexto/permissões | RPC `get_current_user_admin_context` | `/auth/me` | LAJE-85 |
| leitura de jogos | acesso direto a `matches` | `GET /matches` e `GET /matches/{id}` | LAJE-86 |
| controle ao vivo | update direto de `matches` | `/start`, `/scoreboard`, `/finish` | LAJE-86 |
| campeonatos públicos | consulta direta ao Supabase | `GET /championships` | LAJE-86/LAJE-87 conforme domínio final |
| classificação | tabelas/RPCs de standings | `GET /championships/{id}/standings` | LAJE-86 |
| agenda pública | consulta direta de partidas/configuração | `GET /championships/{id}/calendar` | LAJE-86 |

## Compatibilidade e evolução

Durante a migração, o frontend pode manter adapters separados para Supabase e `laje-api`, selecionados por ambiente/feature flag, desde que ambos produzam o mesmo modelo consumido pelas telas. O objetivo é permitir validação em integration/staging antes do corte de produção.

Mudanças incompatíveis nestes contratos exigem revisão explícita da LAJE-84/OpenAPI ou uma nova versão da API. A implementação não deve ajustar silenciosamente payloads para “combinar” com detalhes do banco.

## Checklist de implementação para LAJE-85/LAJE-86

Antes de considerar cada endpoint implementado:

- remover `x-implementation-status: planned` daquele endpoint;
- implementar validação HTTP e regra de domínio;
- implementar autorização quando aplicável;
- adicionar testes unitários e HTTP/E2E;
- validar erros contratuais;
- confirmar que nenhum acesso direto equivalente ao Supabase permanece no fluxo migrado;
- validar o fluxo no ambiente de integration/staging;
- atualizar frontend e documentação sem quebrar o contrato publicado.
