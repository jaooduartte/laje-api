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

O comando `test:coverage` usa c8 v10.1.3 com `--all` para incluir todo o código de produção de `src/**/*.ts` (inclusive arquivos nunca importados pelos testes) e exigir **75% das linhas reais**. Arquivos vazios não contêm linhas executáveis. O pacote de instrumentação está fixado na versão do comando, mas é resolvido pelo npm em execução. O CI grava `coverage/backend/coverage-summary.json`, `coverage/backend/lcov.info`, `coverage/backend/index.html` e o log `coverage/backend/node-test-coverage.txt`, publicando o artefato `laje-api-backend-coverage` mesmo em caso de falha.

**Auditoria do denominador**: a ferramenta anterior (cobertura nativa do Node) reportava 96,75% porque limitava o denominador a módulos carregados. A partir desta configuração, arquivos de `src` não importados entram com cobertura zero. A aprovação exige relatório com o denominador inteiro, e não apenas o percentual da ferramenta anterior.

## Evidência dos três fluxos prioritários

**Autenticação administrativa:** `tests/unit/auth.service.test.ts` cobre login, sessão e token. O teste `tests/e2e/priority-flows.test.ts` verifica validação HTTP. Ainda é necessário testar login e permissões com frontend e banco em staging.

**Operação ao vivo de jogos:** `tests/e2e/priority-flows.test.ts` verifica proteção HTTP contra mutações sem autenticação. `tests/unit/standings.service.test.ts` cobre regras de classificação. Ainda é preciso validar iniciar, atualizar placar e finalizar partida, incluindo efeitos derivados.

**Consulta pública de campeonatos, classificação e calendário:** `tests/e2e/priority-flows.test.ts` verifica validação HTTP; `tests/unit/standings.service.test.ts` e `tests/unit/calendar-ics.test.ts` cobrem regras pertinentes. Ainda falta validar os três recursos públicos com dados de staging.

`npm run test:smoke` roda os testes indicados, com entradas sintéticas e sem conexão de escrita à produção. **Teste de contrato ou validação isolada não equivale à evidência de fluxo completo ponta a ponta.** A integração final deve ser exercitada em staging e comprovada em registros da prova de autoria.

## Processo TDD

Manter testes reproduzindo o defeito antes da correção, implementar a solução mínima, refatorar e anexar os links dos commits, CI e relatórios ao PR. Nunca usar uma base de produção como fixture.

A plataforma operacional atual permanece isolada; estes testes não executam migrações nem writes na base real.
