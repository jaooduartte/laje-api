# Runbook de cutover da LAJE-88

## Estado validado em staging

Em 05/10/2026 foi executado um ensaio real Supabase -> RDS PostgreSQL 17 de staging.

- um snapshot manual do RDS foi criado antes da primeira escrita;
- a primeira tentativa de sincronização falhou porque o staging ainda não possuía as tabelas incrementais de autenticação da LAJE-85;
- o `--single-transaction` confirmou rollback completo, sem dados parciais no destino;
- a migration incremental necessária foi aplicada e a sincronização real seguinte concluiu;
- durante a validação, a origem permaneceu ativa e recebeu novas escritas: as solicitações de reserva passaram de 39 para 41 e o calendário de feriados teve `updated_at` alterado depois do dump;
- por esse motivo, a paridade estrita pós-sync detectou drift legítimo entre dois instantes diferentes da origem, e não evidência de perda durante a importação;
- o executor temporário permanece parado fora das janelas de ensaio para reduzir custo. Segredos e credenciais não devem ser exibidos em terminal, logs, Jira ou GitHub.

Esse ensaio valida a mecânica de exportação, importação, rollback transacional e diagnóstico. Ele não substitui o gate de paridade do cutover final.

## Modos de validação de paridade

`migration:verify-parity` aceita `MIGRATION_PARITY_MODE` com três modos:

- `strict`: comportamento padrão e retrocompatível;
- `rehearsal`: usado em ensaios com origem ainda ativa. A validação continua estrita e retorna código diferente de zero quando encontra diferenças, mas a mensagem deixa explícito que é necessário investigar drift da origem antes de classificar o resultado como perda de migração;
- `final`: usado somente no cutover. Exige `MIGRATION_SYNC_MODE=final` e `MIGRATION_WRITES_PAUSED_AT` preenchido. Qualquer divergência bloqueia o corte.

O modo `rehearsal` não transforma divergências em sucesso. Ele apenas fornece o contexto operacional correto para uma origem que continua recebendo escrita.

## Preparação

1. Confirmar que LAJE-33, LAJE-37, LAJE-89, LAJE-126 e LAJE-136 foram concluídas ou que não exista dependência transitória capaz de impedir os fluxos finais da API, publicação, jobs ou realtime.
2. Revisar o custo estimado de RDS, API, rede e recursos temporários contra os créditos AWS restantes antes de provisionar produção.
3. Reutilizar ou recriar um executor temporário autorizado por SSM com acesso à origem Supabase e ao RDS privado. O executor deve permanecer parado ou ser removido fora das janelas de migração.
4. Criar o RDS de produção a partir de `production.tfvars.example`, usando estado Terraform próprio e sem reutilizar VPC, estado ou credenciais de staging.
5. Aplicar baseline e migrations incrementais no RDS de produção vazio por `scripts/apply-rds-baseline.sh`, com `PGHOST`, `PGUSER`, `PGDATABASE`, `PGPASSWORD`, `PGSSLROOTCERT`, `PGSSLMODE=verify-full` e os gates de execução controlada, a partir de uma execução temporária autorizada na VPC.
6. Carregar conexões de origem e destino por Secrets Manager e confirmar TLS, CA e conectividade sem imprimir URLs ou senhas.
7. Executar `npm run migration:export-schema` para registrar somente o checksum estrutural da origem.
8. Medir o tamanho atual de `public` na origem e do banco de destino. Manter os guardrails padrão do `migration:sync-data` quando suficientes; se for necessário ampliá-los, definir explicitamente `MIGRATION_MAX_SOURCE_PUBLIC_BYTES` e `MIGRATION_MAX_DESTINATION_DATABASE_BYTES` com margem documentada e ainda abaixo da capacidade provisionada.
9. Confirmar que nenhum fluxo de rehearsal está tentando copiar `championship_bracket_preview_private`: o sync de dados é exclusivamente do schema `public`.
10. Antes do corte, executar ao menos um rehearsal no staging. Usar `MIGRATION_PARITY_MODE=rehearsal` no `migration:verify-parity` e registrar apenas evidências agregadas, sem PII. Se houver diferenças, verificar se a origem sofreu alterações após o início do dump antes de classificar o resultado como falha da migração.

## Merge do tooling x conclusão da tarefa

A PR que versiona o tooling, o Terraform, o runbook e os validadores da LAJE-88 pode ser mesclada em `main` antes do cutover produtivo, desde que CI e reviews estejam aprovados. Isso permite que staging, deploy e o próprio cutover usem código já versionado e rastreável.

O merge da PR não conclui a LAJE-88. A tarefa permanece aberta até que o PostgreSQL gerenciado de produção seja o banco principal, o cutover seja validado e o rollback esteja documentado e praticável.

## Janela de corte final

1. Criar snapshot manual do RDS de produção e confirmar backups automáticos habilitados.
2. Colocar todas as gravações que ainda atingem o Supabase em manutenção controlada. Somente depois da pausa efetiva registrar o horário em `MIGRATION_WRITES_PAUSED_AT`.
3. Com a origem congelada, capturar o número esperado de solicitações de reserva diretamente da origem e armazená-lo em `MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT`. Não usar uma contagem histórica fixa no runbook.
4. Definir `MIGRATION_SYNC_MODE=final`, manter `MIGRATION_EXECUTION_CONTEXT=controlled` e `MIGRATION_ALLOW_DESTINATION_WRITE=true`, confirmar os dois orçamentos de storage com as métricas capturadas na própria janela de corte e só então executar `npm run migration:sync-data`.
5. Definir `MIGRATION_PARITY_MODE=final` e executar `npm run migration:verify-parity`. O comando deve validar tabelas, IDs, checksums, estrutura, enums, distribuição de status, FKs e a contagem capturada após o write freeze.
6. Qualquer diferença no modo `final` bloqueia o cutover. Não liberar escrita no RDS até a causa ser entendida e a paridade estrita passar.
7. Executar smoke tests da API pelo endpoint de produção, incluindo autenticação de primeiro acesso, leitura pública, administração de eventos, reservas e operação de campeonatos.
8. Somente após paridade e smoke tests, configurar a aplicação produtiva para usar a `laje-api` conectada ao RDS e liberar tráfego de escrita.
9. Registrar a evidência do corte sem dados pessoais, dumps ou credenciais.

## Rollback

Antes de liberar escrita no RDS, falha de paridade, smoke test ou healthcheck exige manter ou retornar a aplicação ao Supabase e isolar o RDS para análise. Depois de liberar escrita no RDS, não retorne o tráfego ao Supabase sem uma reconciliação reversa aprovada; use recuperação controlada do RDS ou transferência auditada dos registros criados após o corte.

O snapshot anterior à sincronização final deve permanecer disponível durante a janela de estabilização.

## Encerramento

Confirmar saúde da API, conectividade TLS, logs, alarmes, custos e backup. Não remover o Supabase até a estabilização e a documentação do deploy final. Concluir LAJE-88 somente quando o RDS PostgreSQL gerenciado for a persistência principal da produção e as evidências finais de paridade, smoke test e rollback estiverem registradas.
