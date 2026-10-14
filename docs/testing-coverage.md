# LAJE-38 — estratégia de cobertura e smoke tests do backend

## Metas e responsabilidades

A diretriz [Web Apps do Portfólio](https://github.com/CatolicaSC-Portfolio/The-Portfolio-Playbook/blob/main/directions/portfolio-directions-webapp.md) exige **75% de cobertura unitária no backend**, **25% no frontend**, TDD e no mínimo três fluxos completos. O frontend é medido em `jaooduartte/laje`, de maneira independente.

## Reprodução

```bash
npm ci
npm run test:unit
npm run test:e2e
npm run test:smoke
npm run test:coverage
```

O comando `test:coverage` usa cobertura nativa de Node.js 22, filtrando `src/**/*.ts` e exigindo um mínimo de **75% das linhas instrumentadas pelos testes unitários**. O CI grava `coverage/backend/node-test-coverage.txt` e publica o artefato `laje-api-backend-coverage` mesmo em caso de falha.

**Limitação importante**: o coletor nativo do Node contabiliza módulos carregados nos testes. Módulos ainda não importados podem não entrar no denominador. Por isso, **75% no relatório nativo não prova, isoladamente, 75% de todo o backend**. É necessário auditar o escopo de arquivos antes da prova de autoria, complementar testes unitários para módulos ainda não instrumentados e confrontar os percentuais com a definição exigida pelo avaliador. Não anunciar cobertura acadêmica atendida até documentar esse resultado verificável.

## Evidência dos três fluxos prioritários

**Autenticação administrativa:** `tests/unit/auth.service.test.ts` cobre login, sessão e token. O teste `tests/e2e/priority-flows.test.ts` verifica validação HTTP. Ainda é necessário testar login e permissões com frontend e banco em staging.

**Operação ao vivo de jogos:** `tests/e2e/priority-flows.test.ts` verifica proteção HTTP contra mutações sem autenticação. `tests/unit/standings.service.test.ts` cobre regras de classificação. Ainda é preciso validar iniciar, atualizar placar e finalizar partida, incluindo efeitos derivados.

**Consulta pública de campeonatos, classificação e calendário:** `tests/e2e/priority-flows.test.ts` verifica validação HTTP; `tests/unit/standings.service.test.ts` e `tests/unit/calendar-ics.test.ts` cobrem regras pertinentes. Ainda falta validar os três recursos públicos com dados de staging.

`npm run test:smoke` roda os testes indicados, com entradas sintéticas e sem conexão de escrita à produção. **Teste de contrato ou validação isolada não equivale à evidência de fluxo completo ponta a ponta.** A integração final deve ser exercitada em staging e comprovada em registros da prova de autoria.

## Processo TDD

Manter testes reproduzindo o defeito antes da correção, implementar a solução mínima, refatorar e anexar os links dos commits, CI e relatórios ao PR. Nunca usar uma base de produção como fixture.

A plataforma operacional atual permanece isolada; estes testes não executam migrações nem writes na base real.
