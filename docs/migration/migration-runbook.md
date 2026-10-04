# Runbook de cutover da LAJE-88

## Preparação

1. Confirmar que LAJE-33, LAJE-37 e LAJE-89 foram concluídas e que os fluxos API, publicação e realtime foram validados em staging.
2. Revisar o custo estimado de RDS, API, rede e recursos temporários contra os créditos AWS restantes.
3. Criar o RDS de produção a partir de `production.tfvars.example`, usando estado Terraform próprio e sem reutilizar VPC, estado ou credenciais de staging.
4. Aplicar baseline e migration de autenticação no RDS de produção a partir de uma execução temporária autorizada na VPC.
5. Carregar conexões de origem e destino por Secrets Manager e confirmar TLS, CA e conectividade.
6. Executar `npm run migration:export-schema` para registrar somente o checksum estrutural da origem.
7. Fazer ao menos um ensaio completo de `migration:sync-data` e `migration:verify-parity` no staging com dados sintéticos para PII.

## Janela de corte

1. Criar snapshot manual do RDS de produção e confirmar backups automáticos habilitados.
2. Colocar as gravações do Supabase em manutenção controlada e registrar o horário em `MIGRATION_WRITES_PAUSED_AT`.
3. Executar a sincronização final com `MIGRATION_SYNC_MODE=final`, contexto controlado e autorização de escrita do destino.
4. Executar `MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT=39 npm run migration:verify-parity` e confirmar todas as tabelas, os 39 registros de reserva, IDs, status, checksums e FKs.
5. Executar smoke tests da API pelo endpoint de produção, inclusive autenticação de primeiro acesso, leitura pública, administração de eventos, reservas e operação de campeonatos.
6. Somente após as validações, configurar a aplicação produtiva para apontar a `laje-api` para o RDS e liberar tráfego de escrita.
7. Registrar a evidência do corte sem dados pessoais, dumps ou credenciais.

## Rollback

Antes de liberar escrita no RDS, falha de paridade, smoke test ou healthcheck exige retornar a aplicação ao Supabase e manter o RDS isolado para análise. Depois de liberar escrita no RDS, não retorne o tráfego ao Supabase sem uma reconciliação reversa aprovada; use a recuperação controlada do RDS ou uma transferência auditada dos registros criados após o corte.

## Encerramento

Confirmar saúde da API, conectividade TLS, logs, alarmes, custos e backup. Não remover o Supabase até a estabilização e a documentação do deploy final.
