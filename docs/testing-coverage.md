# LAJE-38 — estratégia de cobertura e smoke tests do backend

## Metas e responsabilidades

A diretriz [Web Apps do Portfólio](https://github.com/CatolicaSC-Portfolio/The-Portfolio-Playbook/blob/main/directions/portfolio-directions-webapp.md) exige **75% de cobertura unitária no backend**, **25% no frontend**, TDD e no mínimo três fluxos completos. O frontend é medido em `jaooduartte/laje`, de maneira independente.

## Reprodução

```bash
npm ci
npm run test:unit
npm run test:e2e
npm run test:smoke
# Utilizar Node.js 26.8.2 nesta etapa (Node.js 22 para aplicação):
npm run test:coverage
# Para execução com PostgreSQL descartável, ver preparação abaixo:
npm run test:flows
```

O comando `test:coverage` requer Node.js **26.8.2** para usar a opção nativa `--test-coverage-include-all`, indisponível no Node 22 da aplicação. O pipeline mantém Node 22 para os testes, o lint, o typecheck e o build, e usa Node 26.8.2 **somente na aferição**. Esta opção inclui todos os fontes `src/**/*.ts` não carregados, reportando-os como 0%; exige 75% das linhas. O CI publica `coverage/backend/node-test-coverage.txt`, mesmo em caso de falha.

**Auditoria do denominador**: a ferramenta antiga no Node 22 reportava 96,75% porque limitava o denominador a módulos carregados. Com a opção nativa da versão 26.8.2, arquivos de `src` não importados entram com cobertura zero. Usar este número para comprovação; não é válido reutilizar o relatório da versão 22. A aprovação exige relatório com o denominador inteiro, e não apenas o percentual da ferramenta anterior.

## Evidência de integração dos três fluxos prioritários

O pipeline executa `npm run test:flows` no job **PostgreSQL Validation** contra um PostgreSQL 17 efêmero e isolado, criado a partir do baseline com **todas as migrations incrementais**. O fixture `tests/flows/priority-flows.test.ts` usa dados sintéticos e faz requisições HTTP reais à aplicação Express, verificando:

1. **Autenticação administrativa:** rejeição de senha incorreta, login, token de acesso, consulta ao perfil autenticado e revogação de sessão.
2. **Operação de partidas:** controle de autorização, transições SCHEDULED → LIVE → FINISHED, atualização de placar, recálculo da classificação e rejeição de encerramento duplicado.
3. **Consulta pública:** listagem de campeonatos, calendário com jogo finalizado e classificação contendo os pontos efetivamente recalculados.

Os testes complementares `tests/unit/http-business-flows.test.ts`, `tests/unit/auth.repository.test.ts`, `tests/unit/calendar-subscription-http.test.ts`, `tests/unit/realtime-read-http.test.ts` e `tests/unit/admin-runtime-queries.test.ts` exercitam limites, permissões, persistência, retorno de jogos ao agendamento, calendários ICS/ETag e filtros administrativos com doubles de banco determinísticos.

No frontend, `jaooduartte/laje` (PR #69) mantém cobertura unitária separada de 25% e smoke tests para os fluxos. A verificação dos fluxos na API atravessa HTTP → regras → banco PostgreSQL real, mas **não é uma sessão completa de navegador integrada à API em homologação**. Essa distinção deve constar da prova de autoria; não atribuir a estes testes a execução de UI end-to-end ou de um ambiente externo.

### Evidências do CI — 14/10/2026

- **API, cobertura integral:** **75,18% de linhas** com Node.js 26.8.2 e `--test-coverage-include-all` (sem excluir rotas não testadas): [execução GitHub Actions #38614389194](https://github.com/jaooduartte/laje-api/actions/runs/38614389194). O artefato `laje-api-backend-coverage` preserva o relatório completo.
- **API, PostgreSQL Validation:** aprovado na mesma execução, incluindo baseline, migrations e `npm run test:flows` em base isolada. Também aprovados o **Quality Gate** e o **Docker Image**.
- **Frontend:** PR #69 com cobertura mínima de 25% aferida e CI aprovado na [execução #38519347450](https://github.com/jaooduartte/laje/actions/runs/38519347450). Artefato `laje-frontend-coverage`.

Para reproduzir a integração, preparar **somente uma base descartável** chamada `laje_priority_flows`, aplicar o baseline/migrations conforme `.github/workflows/ci.yml`, definir `DATABASE_URL` para essa base e executar `npm run test:flows`. O próprio teste rejeita DATABASE_URL sem esse identificador. **Nunca utilizar credenciais ou banco de produção**.

## Processo TDD

Manter testes reproduzindo o defeito antes da correção, implementar a solução mínima, refatorar e anexar os links dos commits, CI e relatórios ao PR. Nunca usar uma base de produção como fixture.

A plataforma operacional atual permanece isolada; estes testes não executam migrações nem writes na base real.
