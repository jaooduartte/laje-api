# LAJE-39 — análise estática, segurança contínua e quality gate

## Escopo e atendimento ao Portfólio

Esta implementação atende ao requisito de **análise estática de código e segurança** da linha Web Apps do [The Portfolio Playbook](https://github.com/CatolicaSC-Portfolio/The-Portfolio-Playbook/blob/main/directions/portfolio-directions-webapp.md).
Os repositórios usam GitHub Actions para executar verificações de qualidade e segurança, com análise estática pelo SonarQube Cloud.
Este documento refere-se ao repositório **`jaooduartte/laje-api`**; o outro repositório possui workflow equivalente.

## Ferramentas e execução

- **SonarQube Cloud**: analisa PRs internas para `main` e atualizações de `main`, importa `coverage/backend/lcov.info` e aguarda o Quality Gate para concluir o CI. A integração foi validada em PR e em `main`.
- **Dependency Review**: em toda PR para `main`, reprova dependências novas/vulneráveis High/Critical nos escopos `runtime`, `development` e `unknown`, consultando a base de advisories do GitHub. Não interpreta alterações de lockfile como automaticamente seguras.
- **npm audit**: verifica **toda** a árvore travada em `package-lock.json`, incluindo dependências de desenvolvimento, em PR, push, execução manual e semanal. `npm audit --audit-level=high` reprova High/Critical existentes. O JSON vai para o artefato `laje-npm-audit`; os totais por severidade aparecem no resumo do job.
- **Qualidade e cobertura**: o CI principal permanece responsável por typecheck, ESLint sem warnings, formatação, testes e builds. A cobertura fica separada, sem misturar os denominadores: frontend >=25%; backend >=75%. O workflow de segurança **não substitui** essas medições.

## SonarQube Cloud e substituição do CodeQL — LAJE-151

A análise SonarQube Cloud está ativa para PRs internas destinadas a `main` e para atualizações de `main`. O job aguarda o Quality Gate do Sonar. PRs de forks continuam executando os demais checks, mas não recebem secrets e, por isso, não executam a análise Sonar. A configuração usa `sonar-project.properties` e o LCOV produzido em `coverage/backend/lcov.info` pelo reporter nativo do Node.js 26.8.2; os reporters `spec` e de resumo permanecem ativos.

Cada repositório precisa ter as variáveis `SONAR_ORGANIZATION` e `SONAR_PROJECT_KEY` e o secret `SONAR_TOKEN` cadastrados nas configurações do GitHub. O token não deve ser gravado no repositório nem impresso nos logs. O projeto Sonar precisa estar vinculado ao repositório GitHub correspondente.

O mínimo global de cobertura da API continua em 75% de linhas. No plano Free, o Quality Gate Sonar usa o gate padrão Sonar way, que exige 80% de cobertura em código novo; essa condição é diferente da meta global do projeto. A cobertura global de 75% não substitui nem altera a condição do Sonar para código novo.

As análises Sonar das PRs #78 e #52 e de `main` nos dois repositórios foram aprovadas. Esta segunda etapa propõe remover somente o CodeQL; até o merge desta PR, ele permanece ativo em `main`. `npm audit`, Dependency Review, testes, lint, typecheck, builds e os mínimos globais de cobertura permanecem ativos. Esta migração não altera branch protection, Vercel, AWS/RDS ou Supabase de produção.

## Painéis e evidências para a banca

- [SonarQube Cloud — API](https://sonarcloud.io/dashboard?id=jaooduartte_laje-api): Quality Gate, issues e métricas da análise estática.
- [GitHub Dependabot alerts](https://github.com/jaooduartte/laje-api/security/dependabot): advisories de dependências quando o recurso estiver habilitado para o repositório.
- [GitHub Actions — Security & Dependency Audit](https://github.com/jaooduartte/laje-api/actions/workflows/security.yml): status do Dependency Review, `npm audit`, sumários High/Critical e artefatos JSON.
- [GitHub Actions — CI](https://github.com/jaooduartte/laje-api/actions/workflows/ci.yml): quality gate estático (TypeScript/ESLint/Prettier), testes, cobertura e builds.

Para reproduzir a auditoria das dependências localmente: `npm ci --ignore-scripts && npm audit --audit-level=high`. A análise estática e o Quality Gate são executados pelo workflow do SonarQube Cloud.

## Proteção da branch `main` (recomendação opcional)

As diretrizes do Portfólio Web Apps exigem pipeline CI/CD, análise estática, segurança e cobertura mínima de testes, mas **não exigem explicitamente branch protection ou GitHub rulesets**. Por decisão registrada na [LAJE-147](https://joaoduartte.atlassian.net/browse/LAJE-147), a proteção obrigatória da `main` foi **adiada** e não bloqueia a LAJE-39.

Os workflows de CI e segurança continuam reprovando verificações quando encontram erros de tipagem, lint, formatação, cobertura insuficiente ou vulnerabilidades High/Critical. **Sem checks exigidos por branch protection, esses erros não impedem tecnicamente o merge**. A equipe deve conferir os resultados e não aprovar merges com checks reprovados.

Como melhoria futura opcional, um administrador poderá exigir PR, `Quality Gate`, `Dependency Review (new High/Critical)` e `Dependency Audit (High/Critical gate)`; no backend, também `Full Backend Unit Coverage (75%)`. Não aplicar alteração de ruleset sem autorização.

## Limites e tratamento de achados

SonarQube Cloud identifica problemas de confiabilidade, segurança e manutenção, mas não substitui pentest, validação de autenticação/permissões nem revisão manual. Achados devem receber issue no Jira com severidade, arquivo/regra, impacto e mitigação; correções são tratadas em PRs próprias. Não adicionar exceções silenciosas, alterar thresholds ou omitir dependências para obter um check verde. Dados e credenciais de produção não são lidos nem modificados por estes workflows.

**Observação arquitetural:** o frontend operacional `laje` permanece Vercel/Supabase; a instância de TCC `laje-tcc` usa a API AWS/RDS conforme o plano. Esta etapa altera workflows, documentação e anotações exclusivas do CodeQL, sem mudança funcional, de banco ou deploy.

## Histórico do primeiro ciclo — 14/10/2026 (superado pelas correções)

- O `npm audit` do backend retornou **0 vulnerabilidades**; o quality gate principal (incluindo cobertura e testes) passou depois da formatação.
- O CodeQL detectou alertas High de **limitação ausente de requisições** (regra `js/missing-rate-limiting`): cinco em `src/modules/auth/auth.routes.ts` e um em `src/modules/brackets/brackets.routes.ts`. A remediação, dimensionada para ECS e testes de abuso, está registrada na [LAJE-146](https://joaoduartte.atlassian.net/browse/LAJE-146). O gate permanece reprovado enquanto houver achados graves.
- Dois achados `js/bad-tag-filter` pertenciam a testes sintéticos, não ao runtime. O escopo de CodeQL foi delimitado a `src/` e `scripts/` através de `.github/codeql/codeql-config.yml`, excluindo testes e fixtures; as vulnerabilidades de produção permanecem no escopo.
- `Dependency Review` falhou porque **Dependency graph está desabilitado no repositório**. Ativação e branch protection requerem acesso admin e estão documentadas na [LAJE-147](https://joaoduartte.atlassian.net/browse/LAJE-147). Não desabilitar o job para mascarar a falha.
- A PR #44 continua em rascunho e **não pode ser considerada aprovada** até resolver esses impedimentos.

## Validação de integração — 15/10/2026

- A correção das dependências foi incorporada à `main` do frontend na [PR #71](https://github.com/jaooduartte/laje/pull/71): auditoria com **0 Critical e 0 High**; CI com 1.092 testes, 48,75% de cobertura e dois builds; Vercel dos dois projetos em estado READY.
- O rate limiting compartilhado foi incorporado à `main` do backend na [PR #45](https://github.com/jaooduartte/laje-api/pull/45): 0 alertas graves CodeQL, `npm audit` limpo, testes/cobertura PostgreSQL/Docker aprovados. A migration AWS de produção **não foi aplicada** e a API ainda depende de publicação controlada.
- `Dependency Graph` foi habilitado pelo responsável e `Dependency Review` aprovado nos dois repositórios.
- Este workflow deve ser validado novamente **depois** de integrar as correções com a `main`. Não tratar o histórico de falhas acima como resultado atual.
