# Autenticação administrativa da `laje-api`

## Objetivo

A LAJE-85 move a autenticação, a resolução de permissões e a auditoria administrativa para a `laje-api`. Supabase Auth deixa de ser o desenho-alvo desse domínio. Durante a migração incremental, produção pode manter o fluxo legado até o cutover controlado; ambientes configurados com a API dedicada usam o fluxo novo como principal.

## Modelo de sessão

- access token: JWT HS256 de curta duração, assinado somente pela `laje-api`;
- refresh token: valor aleatório de 256 bits entregue em cookie `HttpOnly`;
- o banco persiste apenas SHA-256 do refresh token;
- sessões podem ser revogadas imediatamente no PostgreSQL;
- em produção o cookie usa `Secure` e `SameSite=None` para permitir frontend Vercel -> API AWS por HTTPS;
- o access token é mantido somente em memória no frontend e é recuperado após reload por meio do refresh cookie.

`AUTH_JWT_SECRET` deve ter no mínimo 32 caracteres e nunca deve ser incluído no bundle do frontend. A configuração final deve ser injetada pelo mecanismo de secrets da AWS.

## Persistência

A migration `infra/database/migrations/20260928190000_create_admin_auth.sql` adiciona:

- `public.admin_auth_accounts`: credencial dedicada por usuário administrativo;
- `public.admin_auth_sessions`: sessões revogáveis e rotação de refresh token.

As tabelas já existentes continuam sendo a fonte de autorização e auditoria:

- `admin_user_profiles`;
- `admin_profiles`;
- `admin_profile_permissions`;
- `admin_action_logs`.

A migration é incremental e não modifica o baseline consolidado.

## Endpoints

- `POST /api/v1/auth/login-state`: resolve primeiro acesso sem expor e-mail de autenticação;
- `POST /api/v1/auth/password-setup`: define a senha de um usuário `PENDING` e cria a primeira sessão;
- `POST /api/v1/auth/sessions`: login por `loginIdentifier` e senha;
- `POST /api/v1/auth/sessions/refresh`: rotaciona refresh token e emite novo access token;
- `DELETE /api/v1/auth/sessions/current`: revoga a sessão atual;
- `GET /api/v1/auth/me`: devolve identidade, perfil e permissões resolvidos no backend;
- `PATCH /api/v1/auth/password`: troca a senha e revoga as demais sessões do usuário.

## Autorização

`GET /auth/me` devolve as permissões efetivas do perfil registradas em `admin_profile_permissions`. A `laje-api` disponibiliza middleware reutilizável para exigir autenticação e permissão `VIEW` ou `EDIT`. A UI pode usar o mesmo contexto para visibilidade, mas a autorização de operações protegidas deve ocorrer novamente no backend.

## Auditoria

Login e definição/troca de senha escrevem em `admin_action_logs` com `metadata.source = "laje-api"`. A auditoria é gravada na mesma transação das alterações críticas de credencial/sessão quando aplicável.

## Migração das credenciais atuais

A LAJE-85 cria e testa a arquitetura de autenticação, mas não extrai credenciais de produção do Supabase. O cutover de dados pertence à LAJE-88.

Para usuários atualmente `ACTIVE`, a LAJE-88 deve escolher e documentar uma das estratégias antes de ativar `VITE_API_URL` em produção:

1. migrar hashes compatíveis para `admin_auth_accounts` por procedimento controlado e auditável; ou
2. marcar a credencial dedicada para redefinição e executar novo primeiro acesso.

Usuários `PENDING` seguem o endpoint de primeiro acesso da `laje-api`. Não se deve tornar o RDS público nem copiar credenciais para arquivos versionados para facilitar a migração.

## Configuração

Backend:

```text
AUTH_ENABLED=true
AUTH_JWT_SECRET=<secret AWS>
AUTH_JWT_EXPIRES_IN=15m
AUTH_REFRESH_EXPIRES_IN_DAYS=30
```

Frontend:

```text
VITE_API_URL=https://<api>/api/v1
```

A ausência de `VITE_API_URL` mantém temporariamente o fluxo Supabase para compatibilidade durante a migração. Isso não representa a arquitetura final.
