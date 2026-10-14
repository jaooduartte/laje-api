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

O comando `test:coverage` requer Node.js **26.8.2** para usar a opção nativa `--test-coverage-include-all`, indisponível no Node 22 da aplicação. O pipeline mantém Node 22 para os testes, o lint, o typecheck e o build, e usa Node 26.8.2 **somente na aferição**. Esta opção inclui todos os fontes `src/**/*.ts` não carregados, reportando-os como 0%; exige 75% das linhas. O CI publica `coverage/backend/node-test-coverage.txt`, mesmo em caso de falha.

**Auditoria do denominador**: a ferramenta antiga no Node 22 reportava 96,75% porque limitava o denominador a módulos carregados. Com a opção nativa da versão 26.8.2, arquivos de `src` não importados entram com cobertura zero. Usar este número para comprovação; não é válido reutilizar o relatório da versão 22. A aprovação exige relatório com o denominador inteiro, e não apenas o percentual da ferramenta anterior.

## Evidência dos três fluxos prioritários

**Autenticação administrativa:** `tests/unit/auth.service.test.ts` cobre login, sessão e token. O teste `tests/e2e/priority-flows.test.ts` verifica validação HTTP. Ainda é necessário testar login e permissões com frontend e banco em staging.

**Operação ao vivo de jogos:** `tests/e2e/priority-flows.test.ts` verifica proteção HTTP contra mutações sem autenticação. `tests/unit/standings.service.test.ts` cobre regras de classificação. Ainda é preciso validar iniciar, atualizar placar e finalizar partida, incluindo efeitos derivados.

**Consulta pública de campeonatos, classificação e calendário:** `tests/e2e/priority-flows.test.ts` verifica validação HTTP; `tests/unit/standings.service.test.ts` e `tests/unit/calendar-ics.test.ts` cobrem regras pertinentes. Ainda falta validar os três recursos públicos com dados de staging.

`npm run test:smoke` roda os testes indicados, com entradas sintéticas e sem conexão de escrita à produção. **Teste de contrato ou validação isolada não equivale à evidência de fluxo completo ponta a ponta.** A integração final deve ser exercitada em staging e comprovada em registros da prova de autoria.

## Processo TDD

Manter testes reproduzindo o defeito antes da correção, implementar a solução mínima, refatorar e anexar os links dos commits, CI e relatórios ao PR. Nunca usar uma base de produção como fixture.

A plataforma operacional atual permanece isolada; estes testes não executam migrações nem writes na base real.
