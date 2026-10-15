# LAJE-39 — análise estática, segurança contínua e quality gate

## Escopo e atendimento ao Portfólio

Esta implementação atende ao requisito de **análise estática de código e segurança** da linha Web Apps do [The Portfolio Playbook](https://github.com/CatolicaSC-Portfolio/The-Portfolio-Playbook/blob/main/directions/portfolio-directions-webapp.md).
Ambos os repositórios públicos usam GitHub Actions e GitHub Code Scanning, sem depender de contas externas ou segredos adicionais.
Este documento refere-se ao repositório **`jaooduartte/laje-api`**; o outro repositório possui workflow equivalente.

## Ferramentas e execução

- **CodeQL SAST**: varre JavaScript/TypeScript com `security-extended` no PR para `main`, push para `main`, execução manual e agendamento semanal. O SARIF vai para a aba **Security → Code scanning** e é armazenado como artefato por 30 dias. Um script lê o SARIF original e **reprova qualquer alerta de segurança High (pontuação >=7) ou Critical (>=9)**; falha fechada se o relatório não existe ou é inválido.
- **Dependency Review**: em toda PR para `main`, reprova dependências novas/vulneráveis High/Critical nos escopos `runtime`, `development` e `unknown`, consultando a base de advisories do GitHub. Não interpreta alterações de lockfile como automaticamente seguras.
- **npm audit**: verifica **toda** a árvore travada em `package-lock.json`, incluindo dependências de desenvolvimento, em PR, push, execução manual e semanal. `npm audit --audit-level=high` reprova High/Critical existentes. O JSON vai para o artefato `laje-npm-audit`; os totais por severidade aparecem no resumo do job.
- **Qualidade e cobertura**: o CI principal permanece responsável por typecheck, ESLint sem warnings, formatação, testes e builds. A cobertura fica separada, sem misturar os denominadores: frontend >=25%; backend >=75%. O workflow de segurança **não substitui** essas medições.

## Painéis e evidências para a banca

- [GitHub Code scanning](https://github.com/jaooduartte/laje-api/security/code-scanning): regras, severidade, arquivos atingidos, histórico e alertas.
- [GitHub Dependabot alerts](https://github.com/jaooduartte/laje-api/security/dependabot): advisories de dependências quando o recurso estiver habilitado para o repositório.
- [GitHub Actions — Security & Static Analysis](https://github.com/jaooduartte/laje-api/actions/workflows/security.yml): status das verificações, sumários High/Critical, relatórios SARIF/JSON e datas das execuções.
- [GitHub Actions — CI](https://github.com/jaooduartte/laje-api/actions/workflows/ci.yml): quality gate estático (TypeScript/ESLint/Prettier), testes, cobertura e builds.

Para reproduzir a auditoria das dependências localmente: `npm ci --ignore-scripts && npm audit --audit-level=high`. O CodeQL roda no workflow com a suite `security-extended` e os resultados são analisados pelo script `scripts/ci/codeql-severity-gate.mjs`.

## Regras de bloqueio de merge (configuração do repositório)

**Falha de workflow não impede um merge enquanto os status checks não forem obrigatórios na proteção de `main`.** Um mantenedor com permissão de administração precisa configurar Settings → Rules → Rulesets (ou Branch protection), alvo `main`, exigindo PR antes do merge e status checks:

- `Quality Gate` (CI existente; inclui cobertura frontend quando aplicável);
- `CodeQL SAST (High/Critical gate)`;
- `Dependency Review (new High/Critical)`;
- `Dependency Audit (High/Critical gate)`;
- `Full Backend Unit Coverage (75%)` (CI do backend).

Usar os nomes de checks apresentados efetivamente na PR; confirmar que o ruleset está **ativo e aplicado**, não somente em modo de avaliação. Não tornar jobs condicionais de integração/Docker obrigatórios quando estes forem legitimamente pulados.
Com os checks obrigatórios, High/Critical ou regressão do CI bloqueiam merge. **A integração utilizada para implementar esta tarefa não possui permissão de administração para ativar/verificar rulesets**; essa ativação é uma etapa manual verificável pelo responsável e não deve ser dada como concluída sem evidência.

## Limites e tratamento de achados

CodeQL identifica padrões de risco, não substitui pentest, validação de autenticação/permissões nem revisão manual. Achados devem receber issue no Jira com severidade, arquivo/regra, impacto e mitigação; correções são tratadas em PRs próprias. Não desligar o gate, adicionar exceção silenciosa, alterar thresholds ou omitir dependências para obter um check verde. Dados e credenciais de produção não são lidos nem modificados por estes workflows.

**Observação arquitetural:** o frontend operacional `laje` permanece Vercel/Supabase; a instância de TCC `laje-tcc` usa a API AWS/RDS conforme o plano. Este trabalho modifica apenas o CI e a documentação, sem mudanças no banco ou deploy.

## Resultado do primeiro ciclo — 14/10/2026

- O `npm audit` do backend retornou **0 vulnerabilidades**; o quality gate principal (incluindo cobertura e testes) passou depois da formatação.
- O CodeQL detectou alertas High de **limitação ausente de requisições** (regra `js/missing-rate-limiting`): cinco em `src/modules/auth/auth.routes.ts` e um em `src/modules/brackets/brackets.routes.ts`. A remediação, dimensionada para ECS e testes de abuso, está registrada na [LAJE-146](https://joaoduartte.atlassian.net/browse/LAJE-146). O gate permanece reprovado enquanto houver achados graves.
- Dois achados `js/bad-tag-filter` pertenciam a testes sintéticos, não ao runtime. O escopo de CodeQL foi delimitado a `src/` e `scripts/` através de `.github/codeql/codeql-config.yml`, excluindo testes e fixtures; as vulnerabilidades de produção permanecem no escopo.
- `Dependency Review` falhou porque **Dependency graph está desabilitado no repositório**. Ativação e branch protection requerem acesso admin e estão documentadas na [LAJE-147](https://joaoduartte.atlassian.net/browse/LAJE-147). Não desabilitar o job para mascarar a falha.
- A PR #44 continua em rascunho e **não pode ser considerada aprovada** até resolver esses impedimentos.
