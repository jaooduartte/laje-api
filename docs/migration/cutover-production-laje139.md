# LAJE-139 — Release final do TCC (`laje-tcc`) na AWS/RDS

> **Situação auditada em 15/10/2026: NO-GO para migração final.** Este runbook não autoriza novas despesas, congelamento da origem, migração final ou alteração de produção. O projeto operacional Vercel `laje` permanece permanentemente no Supabase. O destino da LAJE-139 é exclusivamente o projeto **`laje-tcc`**.

## Ambientes e limites de escopo

<!-- prettier-ignore -->
| Ambiente | Frontend Vercel | Backend e dados | Decisão |
| --- | --- | --- | --- |
| Operacional permanente | `laje` | Supabase | **Nunca** alterar env, credenciais, rotas, tráfego ou dados nesta tarefa, salvo pausa excepcional de escrita expressamente autorizada para produzir um checkpoint consistente. |
| Integração | `laje-tcc` | API AWS em ECS/Fargate + RDS `laje-staging-postgres` | Apenas para testes e ensaios. Não serve como banco de produção do TCC. |
| Release TCC | `laje-tcc` | API **produtiva independente** na AWS + RDS PostgreSQL 17 **produtivo** | Publicar somente após todos os gates GO. |

O repositório frontend é compartilhado, mas cada projeto Vercel tem variáveis próprias. Em `laje-tcc`, usar `VITE_BACKEND_PROVIDER=aws` e `VITE_API_URL=https://<api-producao>/api/v1`. As variáveis `VITE_*` são públicas e são incorporadas ao bundle em **build time**. Alterar variáveis exige **novo build/deploy** somente no projeto `laje-tcc`. Não fazer fallback de `laje-tcc` para Supabase.

### Auditoria AWS/Vercel de 15/10/2026

- Predecessoras da LAJE-139 **concluídas no Jira**: LAJE-33, LAJE-136, LAJE-89, LAJE-126 e LAJE-141. Conclusão de tarefa não substitui novo smoke E2E do release.
- AWS `sa-east-1`: RDS `laje-staging-postgres` PostgreSQL 17.9, `db.t4g.micro`, 20 GiB, **privado**, criptografado, 1 dia de backup; **nenhum RDS de produção** encontrado no inventário consultado.
- ECS `laje-staging-api`: serviço ativo, `desired=1`, `running=1`, task definition revisão `:31`; ALB interno e ECR de staging presentes.
- API Gateway atualmente utilizado no staging: `rkckaptyaf`. Outro API Gateway `96bmsmgbt0` existe sem tráfego confirmado; examinar o Terraform state antes de eventual limpeza, sem exclusão manual improvisada.
- Vercel: ambos `laje` e `laje-tcc` possuem deployment `READY`; `VITE_API_URL` de `laje-tcc` aponta atualmente para o endpoint **de staging**, não para um release definitivo.
- Cost Explorer consultado para os 15 dias encerrados em 15/10/2026 não apresentou valores de cobrança acima de US$ 0,001 por serviço/dia nos resultados retornados. **Isso não demonstra custo futuro zero**: validar elegibilidade a créditos, período de apuração, limites e preços antes de aprovar infraestrutura permanente.
- Como o ECS e o ALB estão ativos, existe exposição potencial a cobranças recorrentes; usar o workflow manual `deploy-aws.yml` com `action=suspend` após concluir os testes de staging, observando os recursos que ele preserva.

## Gate 0 — Aprovações e testes prévios

1. Registrar no Jira aprovador, responsáveis pela aplicação e banco, janela de manutenção, duração máxima do congelamento de escrita, plano de comunicação e limites orçamentários.
2. Revisar CI, segurança, cobertura e peer review de `laje` e `laje-api`. Executar smoke dos fluxos de autenticação/primeiro acesso, campeonatos, jogos ao vivo/realtime e reconexão, classificação, chaves, calendário/ICS, reservas/e-mails e workloads SQS/EventBridge. Registrar a execução com logs **sem dados pessoais**.
3. Verificar por consulta independente que o projeto `laje-tcc` não referencia Supabase como backend principal e que `laje` **não** referencia a API AWS.
4. Confirmar e **testar** o procedimento de congelamento de escritas no Supabase de origem: interface, APIs externas, jobs, triggers, Edge Functions e todas as demais fontes. A origem operacional continua existindo; o freeze é **temporário e excepcional**, somente com autorização expressa.
5. Se não for possível garantir freeze e consistência sem prejudicar `laje`, **NO-GO**. Revisar/autorizar formalmente uma técnica alternativa de captura consistente antes de modificar os scripts; não contornar `MIGRATION_SYNC_MODE=final` nem `MIGRATION_PARITY_MODE=final`.

## Gate 1 — Produção AWS segregada e orçamento

1. Revisar `infra/aws/terraform/production.tfvars.example`; executar `terraform validate` e **plan isolado** com backend `laje/production/terraform.tfstate`, role IAM de produção e sem alterar o state de staging. Revisar plano, preço, créditos e necessidade de recursos antes de `apply`.
2. O módulo existente foi concebido inicialmente para o runtime **staging** (`staging_api_enabled`). Não presumir que habilitá-lo com `environment=production` entregue uma API prod segregada. Implementar e revisar recursos/roles/workflows exclusivos de produção (ECS, ECR, API Gateway + VPC Link + ALB, log group, alarmes e secrets), evitando NAT Gateway quando houver desenho seguro mais econômico.
3. Provisionar RDS produtivo **somente perto da janela aprovada**. Exigir TLS, `publicly_accessible=false`, SG restrito, criptografia, backup, deletion protection e snapshot identificável. Se a conta AWS limitar retention a 1 dia, registrar e aprovar mitigação **antes** da criação.
4. Validar execução de migrations versionadas a partir da rede privada, saúde da API e conectividade. Não editar baseline nem migrations já aplicadas. Nenhuma credencial em Git, frontend, logs ou tickets.
5. Preservar plano de rollback de infraestrutura e dados. Testar restore de backup sem usar o banco de staging como destino produtivo.

## Gate 2 — Checkpoint consistente e sincronização final

1. Criar backup consistente da origem e snapshot manual do RDS de destino antes da escrita de migração; identificar restauração, retenção e responsável.
2. Aplicar baseline e todas as migrations da API de forma versionada. Executar rehearsal recente para antecipar incompatibilidades.
3. Na janela autorizada, comprovar tecnicamente a **ausência de escritas na origem**. Registrar início (UTC com timezone), método de bloqueio, responsável e múltiplas consultas de confirmação; timestamp ou variável de ambiente **não é prova** de freeze.
4. Capturar **após o freeze** a contagem de `reservation_requests` e demais totais críticos. Não reutilizar valores históricos do staging.
5. No executor privado e controlado, usar `MIGRATION_EXECUTION_CONTEXT=controlled`, `MIGRATION_ALLOW_DESTINATION_WRITE=true`, `MIGRATION_TARGET_FRONTEND=laje-tcc`, `MIGRATION_WRITES_PAUSED_AT=<ISO8601-com-fuso>`, `MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT=<inteiro>` e `MIGRATION_SYNC_MODE=final`. A variável de destino é um **gate declarativo**, não comprova qual projeto Vercel foi configurado: conferir o projeto de forma independente.
6. Executar `npm run migration:sync-data` e, depois, `MIGRATION_PARITY_MODE=final npm run migration:verify-parity`, mantendo a origem congelada. Divergência de tabelas, estrutura, enums, checksums, chaves, contagens ou reservas: **NO-GO**.
7. Revalidar que o backup é recuperável, o banco produtivo está privado e a API aponta para o **RDS de produção** (não staging). Autenticação Supabase Auth não é importada automaticamente: executar primeiro acesso administrativo de modo controlado.

## Gate 3 — Publicação e estabilização

1. Manter `laje` operacional apontando **sempre** ao Supabase. Alterar apenas as envs **Production** do projeto Vercel `laje-tcc` e gerar novo deployment. Confirmar pelo bundle e por testes reais que a URL da API final está em uso.
2. Executar smoke E2E HTTPS/TLS/CORS, health de banco, autorização, leitura e escrita de negócios, realtime/reconexão, e-mails, filas/DLQ e integrações. Registrar evidências e versão imutável da API.
3. Após GO registrado, liberar o release do TCC. A cópia inicial de dados do TCC representa um **checkpoint**, não sincronização contínua com `laje`. Registrar claramente que alterações posteriores nos dois ambientes poderão divergir.
4. **Rollback antes da primeira escrita no RDS:** reverter/suspender somente `laje-tcc` e sua API; não direcionar `laje` à AWS. **Depois de escritas no RDS:** não sobrescrever/restaurar cegamente os dados do TCC; reconciliar ou restaurar mediante plano aprovado. A aplicação operacional Supabase não deve ser tratada como réplica automática do novo banco.
5. Definir janela de observação com métricas e alarmes para ECS, API Gateway, RDS, SQS/DLQ, scheduler, segurança, latência, erros e custos. Somente depois do aceite remover recursos temporários identificados no Terraform state, com backup e aprovação.

## Critérios de encerramento e evidências da LAJE-139

Registrar no Jira: PRs/reviews/CI de ambos os repositórios; Terraform plan/apply sem drift de staging; orçamento autorizado; AWS e Vercel IDs (sem secrets); snapshot e backup restauráveis; freeze temporário **autorizado e comprovado**; contagens capturadas durante a janela; `sync-data` e `verify-parity` em modo `final`; smoke do frontend `laje-tcc` na API produtiva/RDS produtivo; rollback testado; custos pré e pós-publicação; comprovação de que o projeto operacional `laje` permaneceu em Supabase.

**NO-GO enquanto não houver:** RDS/API produtivos, política de freeze aprovada, dados/backup/checkpoint válidos, paridade final, smoke E2E e período de rollback definidos. Nenhuma dessas condições pode ser marcada como concluída apenas com testes de staging.
