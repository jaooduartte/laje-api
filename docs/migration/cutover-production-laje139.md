# LAJE-139 — Gate de produção: Supabase → AWS RDS

**Estado em 13/10/2026:** NO-GO para cutover. A produção atual `laje` na Vercel continua usando Supabase. O frontend `laje-tcc` e a API ECS/RDS AWS servem somente staging. A LAJE-139 permanece aberta até a execução real dos critérios de aceite; este documento não é autorização de corte.

## Evidência auditada

| Dependência                               | Estado auditado      | Condição para prosseguir                                                              |
| ----------------------------------------- | -------------------- | ------------------------------------------------------------------------------------- |
| LAJE-33 — CI/CD e release AWS de produção | Pendente no Jira     | Workflow de deploy automático e isolado de produção, com rollback de release          |
| LAJE-89 — realtime sem Supabase           | Pendente no Jira     | Placar ao vivo, atualizações públicas e presença equivalente testados no frontend AWS |
| LAJE-126 — jobs, SQS, cron e e-mails      | Concluído            | Smoke prod e observabilidade depois do corte                                          |
| LAJE-136 — API AWS staging                | Concluído            | Configuração de produção e secrets independentes                                      |
| LAJE-141 — runtime AWS-only               | Concluído            | Auditoria de toda dependência residual em frontend e produção                         |
| LAJE-143 — troca de senha RDS e ECS       | Concluído no staging | Infra isolada de produção e alarmes adequados                                         |

A origem Supabase foi conferida em modo **somente leitura** em 13/10/2026: `cugqidtapnqvonbdbbdf` está `ACTIVE_HEALTHY`, com 41 solicitações de reserva na hora da consulta e ~37 MB nas relações do schema `public`. **Esses números são históricos, não servem como parâmetros fixos do corte.** Em 05/10, o rehearsal validou exportação/importação/rollback transacional, mas registrou drift com a origem ativa. Não comprova paridade final.

O RDS AWS existente é apenas `laje-staging-postgres`, privado, classe `db.t4g.micro`, backup de 1 dia. Nenhum RDS produtivo foi provisionado, respeitando o controle de custos e o isolamento de ambientes.

## Gate 0 — Não executar antes das dependências

1. Confirmar **LAJE-89** finalizada com o frontend AWS substituindo `useLiveChampionshipRealtime`. Atualmente esse hook retorna cedo quando `isSupabaseBackendEnabled() === false`; portanto placar/atualizações em tempo real ficam sem assinatura no modo AWS. A solução deve incluir teste de atualização e reconexão, além de estratégia de presença ou decisão documentada.
2. Confirmar **LAJE-33** concluída para release do backend produtivo com CI, imagens imutáveis, observabilidade, permissões IAM específicas, health checks e rollback. O workflow atual `deploy-aws.yml` implanta **staging** por `workflow_dispatch`; o gatilho `push` ainda referencia a branch temporária `LAJE-136`, não a main.
3. Validar caminhos de autenticação administrativa, first-access após importação, regras de negócio, reservas e envios de e-mails, jogos e standings, calendário/ICS e filas via API dedicada; revisar [Matriz de compatibilidade](compatibility-matrix.md) e [Runbook LAJE-88](migration-runbook.md). Documentar evidências de QA cruzado e revisão por pares exigidas pelo Playbook.
4. Validar procedimento concreto de **write freeze**: bloquear mutações tanto na interface atual quanto nos endpoints de Supabase ainda diretamente acessíveis (incluindo tarefas e triggers que geram escrita), registrar responsável e horário UTC, e comprovar inatividade por consultas repetidas. Um timestamp informado por variável **não bloqueia** escrita.
5. Designar operadores, janela aprovada, tempo máximo de indisponibilidade, canal de comunicação, URL produtiva final e critérios de GO/NO-GO. Sem janela e congelamento real, proibir `MIGRATION_SYNC_MODE=final`.

## Gate 1 — Infraestrutura produtiva e custo

- Revisar orçamento AWS, créditos disponíveis e uso atual do staging. Definir plano de desligamento/suspensão de recursos não necessários; evitar NAT Gateway e máquinas permanentes de migração.
- Somente próximo da janela, usar `infra/aws/terraform/production.tfvars.example` como referência, com estado Terraform **`laje/production/terraform.tfstate` distinto**, VPC `10.43.0.0/16`, RDS `laje-production-postgres` e segredos independentes. Verificar que o `terraform plan` **não altera staging**.
- Guardrails de dados: banco criptografado, RDS não público, TLS obrigatório, SG estrito `app → RDS`, backup, deletion protection e snapshot. O AWS Free Plan pode restringir a retenção para um dia; não reduzir o backup de produção sem aprovação e mitigação documentada.
- Configurar runtime ECS/API Gateway de **produção** e seus segredos sem reusar `laje-tcc`, staging ou deploy OIDC de staging. A configuração `staging_api_enabled` do Terraform atual não equivale à infraestrutura prod; implementação específica será necessária.
- Preparar executor temporário via SSM na VPC com acesso TLS ao Supabase de origem e RDS privado, sem expor `DATABASE_URL` e credenciais.

## Gate 2 — Checkpoint e migração final

1. Criar backup consistente da **origem** por método compatível com o plano Supabase e snapshot manual do RDS de produção imediatamente antes da migração. Confirmar ambos restauráveis e independentes do staging.
2. Aplicar baseline consolidado e migrations incrementais versionadas ao RDS vazio. **Não editar migrations antigas.**
3. Executar rehearsal recente, sem depender da paridade enquanto a origem ainda recebe escrita.
4. Entrar em manutenção; bloquear e comprovar ausência de **todas** as escritas, inclusive tarefas automáticas. Anotar UTC e contagem final de reservas **obtida nessa janela**, nunca copiar as 41 reservas da auditoria anterior.
5. Definir `MIGRATION_WRITES_PAUSED_AT` como timestamp ISO 8601 completo com timezone, `MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT` como inteiro não negativo capturado **após o freeze** e `MIGRATION_SYNC_MODE=final`. `scripts/migration/sync-data.ts` recusa final se esses metadados não forem válidos, além de exigir `MIGRATION_EXECUTION_CONTEXT=controlled`, `MIGRATION_ALLOW_DESTINATION_WRITE=true`, destino distinto e orçamento de armazenamento suficiente. A validação não comprova o freeze: operador precisa verificá-lo fora do script.
6. Executar `npm run migration:sync-data` sob contexto controlado, em canal sem logs/artefatos de PII. O `pg_dump --schema=public` é transferido por pipe e importado com transação no RDS.
7. Definir `MIGRATION_PARITY_MODE=final` e executar `npm run migration:verify-parity`. A validação recusa contagem esperada ausente/inválida e compara tabelas, contagens, PKs, checksum de dados, estrutura, enums, FKs e status de reservas. **Qualquer diferença → NO-GO**, sem trocar tráfego ou liberar escrita no RDS.
8. Confirmar permissões administrativas e fluxo de primeiro acesso. As senhas Supabase Auth não são migradas; `admin_auth_accounts`/sessions começam vazias e perfis requerem reconfiguração controlada.

## Gate 3 — Cutover e estabilização

- Preparar antes da janela o ambiente Vercel produtivo `laje` com `VITE_BACKEND_PROVIDER=aws` e `VITE_API_URL=https://<api-prod>/api/v1`, sem inserir valores do RDS no frontend. Como Vite insere variáveis **na compilação**, uma alteração de env exige build/deploy explícito. Apenas alterar env no console não muda o bundle existente.
- Executar smoke **na API produtiva** (auth primeiro acesso, jogos/placares, público/calendário/ICS, eventos e reservas/e-mails, operações administrativas, permissões) e confirmar a origem congelada, parity=100%, backups e rollback ainda disponíveis.
- Fazer o deployment Vercel produtivo e liberar escrita no RDS só após GO documentado. Evitar dual-write não controlado.
- Observar ECS/API Gateway/RDS, latência e erros, Lambda/scheduler/SQS/DLQ, fluxos realtime, alarmes CloudWatch e custo, com rollback de aplicação pronto.
- **Antes de qualquer escrita no RDS:** erro implica manter/retornar tráfego ao Supabase preservando a origem congelada. **Depois de escrita no RDS:** nunca alternar simplesmente o frontend de volta ao Supabase; exige reconciliação inversa ou recuperação aprovada no RDS. O rollback deve ser exercitado previamente e possuir decisor nomeado.
- Não remover Supabase, backups, secrets ou snapshots durante janela de estabilização. Após o período aprovado, reduzir staging, desativar recursos obsoletos e auditar custos AWS antes/depois.

## Evidências exigidas para encerrar Jira LAJE-139

Registrar links de CI/reviews, `terraform plan` e execução produtiva, identidade dos ambientes, snapshot/backup identificados, congelamento confirmado (UTC), contagens pós-freeze, resultado de sincronização e paridade `final`, resultados de smoke/QA, deploy efetivo `laje` → API AWS produção → RDS produção, janela de estabilização, teste de rollback e inventário de custos. **Não incluir dumps, credenciais, PII ou valores de segredo**.

**Situação hoje: NO-GO.** LAJE-33 e LAJE-89 estão pendentes. O Supabase produtivo permanece intocado, e o RDS de produção não deve ser criado antecipadamente.
