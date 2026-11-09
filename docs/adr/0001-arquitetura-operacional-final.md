# ADR 0001 — Arquitetura operacional do LAJE TCC

- Status: Accepted, revisado em 09/11/2026
- Decisão original: 27/09/2026, sob LAJE-82
- Revisão atual: LAJE-37
- Escopo: frontend `laje-tcc`, API `laje-api`, persistência e operação AWS

## Contexto

O Portfólio entrega a versão web `laje-tcc`, com frontend React/Vite na Vercel e backend próprio na AWS. A arquitetura precisa refletir os recursos realmente usados e distinguir evidência operacional atual de planos ou auditorias anteriores.

A Vercel é uma exceção aprovada para hospedar o frontend deste projeto. A API, o banco e os workloads operacionais da entrega são executados na AWS em `sa-east-1`.

## Decisão vigente

Usar o seguinte caminho para a versão pública do TCC:

```text
Navegador
  -> Vercel: laje-tcc
  -> API Gateway HTTP API
  -> VPC Link
  -> ALB interno
  -> ECS / AWS Fargate: laje-api
  -> Amazon RDS for PostgreSQL 17
```

`laje-staging-postgres` é o único RDS AWS selecionado para a entrega TCC. O prefixo `staging` nos nomes AWS e variáveis Terraform é nomenclatura existente; não exige provisionar nem renomear um segundo RDS. O frontend publicado e o desenvolvimento local conectado pelo túnel SSM usam essa mesma instância, com isolamento lógico por contas e fixtures de homologação.

Serviços complementares em uso ou configurados para o ambiente incluem Amazon ECR para imagens imutáveis, AWS Secrets Manager para segredos, CloudWatch para logs e métricas, SQS com DLQ e EventBridge Scheduler para workloads assíncronos.

## Evidência operacional atual

Na consulta de 09/11/2026:

- API Gateway HTTP API `rkckaptyaf` encaminhava a rota `$default` por VPC Link a um ALB interno;
- ECS/Fargate `laje-staging-api` tinha uma tarefa desejada e em execução, deployment concluído e task definition `:36`;
- RDS `laje-staging-postgres` PostgreSQL 17.9 estava disponível e privado;
- os logs da API estavam no grupo `/laje/staging/api`.

Esse registro é uma fotografia da conta nessa data. A validação de uma publicação deve usar a execução correspondente do workflow `Deploy AWS`, seus health checks e um smoke funcional da versão apresentada.

## Rede e segurança

- A API externa é publicada por HTTPS na API Gateway; o ALB é interno e recebe tráfego pelo VPC Link.
- O RDS permanece privado e recebe conexões da aplicação com TLS.
- A API centraliza autenticação, autorização, regras de negócio e acesso ao banco.
- Segredos ficam no AWS Secrets Manager e a automação AWS usa GitHub OIDC.
- As variáveis `VITE_*` não devem conter credenciais ou segredos privados.
- O CORS do ambiente consultado permite a origem `https://laje-tcc.vercel.app`.

## Persistência, backup e recuperação

O RDS consultado estava em Single-AZ, criptografado, com backup automático e retenção configurada de um dia. A proteção contra exclusão não estava habilitada na consulta de 09/11/2026.

Antes de uma alteração destrutiva, crie um snapshot manual identificado com data, motivo e versão da API. Para recuperação, restaure primeiro em uma instância temporária privada e valide migrations, integridade e fluxos de leitura antes de considerar qualquer troca controlada de endpoint. Para reverter uma publicação da API sem incompatibilidade de schema, use uma imagem ECR imutável anterior. O ensaio de restauração não foi executado ou comprovado nesta revisão.

## Deploy e operação

O workflow `Deploy AWS` é manual (`workflow_dispatch`) e limitado à branch `main`. Ele valida Terraform, publica ou reutiliza uma imagem ECR identificada pelo commit, aplica as migrations operacionais no RDS selecionado para o TCC, atualiza o serviço ECS e verifica HTTPS, saúde da API, conexão PostgreSQL, CORS e smoke E2E.

O Terraform define seis alarmes CloudWatch para métricas de SQS/DLQ, idade da fila, CPU e armazenamento do RDS, rotação de credenciais e falhas de entrega do EventBridge. Os alarmes consultados não tinham ação SNS configurada, portanto este ADR não considera notificação por e-mail comprovada. A validação ampliada de observabilidade permanece vinculada à LAJE-40.

## Decisões anteriores e atualização

A decisão original descrevia uma arquitetura futura com recursos separados para integração e produção. A revisão da LAJE-37 substitui essas premissas pelo ambiente TCC verificado: a instância `laje-staging-postgres` é o único RDS selecionado para essa entrega, e o runtime atualmente nomeado como staging atende ao frontend `laje-tcc`.

A auditoria de 15/10/2026 registrada no documento de release permanece como evidência histórica daquela data. Ela não define o estado atual nem exige uma infraestrutura paralela.

## Consequências

- Frontend, API e persistência do TCC têm um caminho de execução documentado e verificável.
- O mesmo RDS é compartilhado pelo frontend publicado e pelo desenvolvimento local via túnel SSM; testes devem usar contas/fixtures identificáveis e preservar dados da demonstração.
- A instância atual tem retenção automática de backup curta, Single-AZ e sem proteção contra exclusão, condições que devem ser consideradas em mudanças de banco.
- Status de tarefas, documentação, configuração Terraform e imagens não substituem evidência do deployment e dos fluxos efetivamente apresentados.

## Evidências e referências

- LAJE-37: atualização da documentação da entrega TCC.
- LAJE-40: validação ampliada de observabilidade.
- LAJE-149: evidência relacionada à homologação e aos fluxos AWS do TCC; consultar a execução e os artefatos vinculados antes de citar um resultado específico.
- [Arquitetura da API](../architecture.md)
- [Publicação](../deployment.md)
- [Runbook AWS](../staging-aws.md)
- [Release do TCC](../migration/cutover-production-laje139.md)
- [Terraform AWS](../../infra/aws/terraform/README.md)
