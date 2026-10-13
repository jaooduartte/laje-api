# LAJE-143 — Atualização automatizada do ECS após rotação de credenciais RDS

## Incidente e objetivo

Em 12/10/2026, o RDS alterou a versão `AWSCURRENT` da senha gerenciada no AWS Secrets Manager, mas a task ECS da `laje-api` continuou com a senha antiga injetada no start. A API retornou HTTP 500 e as mensagens SQS de manutenção falharam (`PostgresError 28P01`) até o reinício manual do serviço. As 526 mensagens obsoletas resultantes foram tratadas na [LAJE-144](https://joaoduartte.atlassian.net/browse/LAJE-144).

Este módulo previne a recorrência **no staging AWS**, sem ler a senha e sem afetar o backend Supabase legado. O uso do frontend Vercel permanece autorizado pelo professor.

## Arquitetura

1. A cada mudança da versão ativa, o AWS Secrets Manager emite nativamente o evento EventBridge `Secret Label Updated` para `AWSCURRENT` no barramento padrão. Não depende do CloudTrail.
2. A regra EventBridge aceita apenas a conta, região e ARN **exato** do segredo master gerenciado pelo RDS de staging.
3. A função Lambda Node.js 22 verifica novamente a origem, o ARN e se o `versionId` do evento possui `AWSCURRENT` via `DescribeSecret`. **Não acessa `GetSecretValue`**.
4. Se o serviço estiver suspenso (`desiredCount=0`), a função sai sem reiniciar tasks. Se a task já iniciou depois da atualização da senha, não reimplanta. Se um deployment estiver em andamento, aguarda estabilização em vez de iniciar outro.
5. A tabela DynamoDB `laje-staging-rds-rotation-lock` usa uma gravação condicional com lease/TTL para serializar execuções concorrentes, sem reservar concorrência da Lambda (a conta AWS tem limite de 10). Uma invocação bloqueada falha e pode ser repetida, sem disparar deployment duplicado.
6. Se a task estiver defasada, chama `UpdateService(forceNewDeployment=true)` **apenas** para `laje-staging-api`; aguarda o ECS estabilizar e verifica que todas as tasks foram iniciadas após a atualização do segredo.
7. Testa tanto `/api/v1/health/database` quanto `/api/v1/public/settings` no endereço do API Gateway. Falhas propagam erro à Lambda e acionam o alarme CloudWatch `laje-staging-rds-rotation-errors`.
8. A trava distribuída e a checagem de versão/task mitigam eventos duplicados. O ECS passa a utilizar mínimo de 100% e máximo de 200% de tasks durante deploy: uma segunda task temporária evita interromper a task saudável. O circuit breaker e rollback limitam implantações defeituosas.

Toda a solução está declarada em Terraform: `infra/aws/terraform/rds-rotation.tf`, handler em `infra/aws/lambda/rds-rotation-handler.mjs`, testes em `tests/unit/rds-rotation-handler.test.mjs`. A Lambda usa o AWS SDK v3 fornecido pelo runtime gerenciado; atualizar a versão do Node e avaliar empacotamento com SDK fixado ao atualizar o ambiente.

**O deploy é feito apenas após revisão humana**, usando o workflow de staging já existente. Durante `suspend`, o Terraform remove os recursos temporários associados ao runtime AWS; ao reativar, a regra é recriada.

## Limites e segurança

- IAM limita `secretsmanager:DescribeSecret` ao ARN de staging e `ecs:UpdateService` ao serviço `laje-staging-api`. Sem permissão para redefinir senha, apagar state ou atualizar serviços de produção.
- Não registrar `SecretString` nos logs. Os registros apresentam somente `outcome` e razões não sensíveis.
- A regra usa `AWSCURRENT`, que também pode avançar em troca manual do segredo. Trata-se de uma atualização efetiva da credencial, não exclusivamente da rotação agendada. Eventos de início/erro ou de outros segredos não acionam deploy.
- Um erro de rotação ou ausência de evento impede nova task. Os alarmes da Lambda e do EventBridge são monitorados, mas eventos não recebidos pelo barramento não geram alarme direto. Acompanhar também erros de autenticação PostgreSQL e o health endpoint.
- O timeout Lambda é de 600 segundos. Se ECS não estabilizar, a função falha de forma observável; a política de retries nativa pode reexecutá-la e as verificações de atualização evitam reinícios redundantes.

## Testes antes do merge

- `npm run test:unit` inclui cenários de evento fora da conta/região, segredo errado, label diferente, versão obsoleta, staging suspenso, restart, idempotência e falha de health.
- `npm run typecheck`, `npm run lint`, `npm run format:check`, `npm run build`.
- `terraform fmt -check -recursive infra/aws/terraform` e `terraform init -backend=false -input=false -lockfile=readonly && terraform validate`.
- Revisão por pares conforme PAC VIII e Playbook de Portfólio. Não efetuar merge automático.

## Validação controlada após merge

1. Conferir custo, segredo exato, `terraform plan` e conta AWS; deploy exclusivamente em staging `sa-east-1`. Confirmar que não existe mudança em recursos Supabase.
2. Verificar que a regra EventBridge, Lambda e alarmes estão ativos. Inspecionar a policy IAM da função e a métrica de invocação.
3. **Não provocar rotação manual no RDS de produção.** Em staging, agendar um teste controlado em janela sem usuários, com aprovação do responsável, antes de rotacionar o segredo. Uma simples simulação do evento somente verifica filtros e não comprova integração RDS → ECS.
4. Acompanhar `Secret Label Updated` → invocação Lambda → novo deployment ECS → novas tasks HEALTHY → health PostgreSQL e endpoints públicos. Confirmar que o worker SQS processa eventos atuais sem preencher DLQ.
5. Repetir evento para mesmo `versionId` e conferir que não há novo deployment. Testar evento de segredo diferente em ambiente de teste para garantir isolamento.
6. Registrar o tempo de recuperação, custo temporário da task extra e logs redigidos na [LAJE-143](https://joaoduartte.atlassian.net/browse/LAJE-143).

## Rollback

Se a automação apresentar problema, desabilitar temporariamente **somente** a regra `laje-staging-rds-rotation`, mantendo a API e a DLQ intactas. Investigar logs e corrigir em PR. Em caso de rotação durante o bloqueio, atualizar manualmente o serviço de staging (`forceNewDeployment=true`) após confirmar o segredo corrente. Nunca reverter o valor do segredo RDS ou copiar chaves para arquivos.

## Fontes

- [AWS Secrets Manager: Secret Label Updated](https://docs.aws.amazon.com/secretsmanager/latest/userguide/secret-event-notifications.html)
- [Exemplo de evento AWSCURRENT](https://docs.aws.amazon.com/secretsmanager/latest/userguide/event-detail-secret-label-updated-secretsmanager.html)
- [Playbook de Portfólio](https://github.com/CatolicaSC-Portfolio/The-Portfolio-Playbook/blob/main/Portfolio.md)
- [PAC Extensionista VIII](https://github.com/CatolicaSC-Portfolio/The-Portfolio-Playbook/blob/main/PAC%20Extensionista%20VIII.md)
