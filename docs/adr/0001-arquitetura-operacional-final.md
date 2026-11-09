# ADR 0001 — Arquitetura operacional do LAJE TCC

- Status: Accepted, revisado em 09/11/2026
- Decisão original: 27/09/2026, sob LAJE-82
- Revisão atual: LAJE-37
- Escopo: frontend `laje-tcc`, API `laje-api`, persistência e operação AWS

## Contexto

O Portfólio documenta a versão web `laje-tcc`, com frontend React/Vite na Vercel e backend próprio na AWS. O projeto Vercel `laje` continua sendo a produção operacional permanente da liga com Supabase. A arquitetura precisa refletir os dois deployments e distinguir evidência operacional atual de planos ou auditorias anteriores.

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

`laje-staging-postgres` é o único RDS AWS selecionado para a entrega TCC. O prefixo `staging` nos nomes AWS e variáveis Terraform é nomenclatura existente; não exige provisionar nem renomear um segundo RDS. O frontend publicado e o desenvolvimento local conectado pelo túnel SSM usam essa mesma instância. O ambiente permanente `laje`/Supabase segue separado e sem sincronização automática.

Serviços complementares em uso ou configurados para o ambiente incluem Amazon ECR para imagens imutáveis, AWS Secrets Manager para segredos, CloudWatch para logs e métricas, SQS com DLQ e EventBridge Scheduler para workloads assíncronos.

## Evidência operacional atual

Na consulta de somente leitura ao plano de controle AWS em 09/11/2026:

- API Gateway HTTP API `rkckaptyaf` encaminhava a rota `$default` por VPC Link a um ALB interno;
- ECS/Fargate `laje-staging-api` tinha uma tarefa desejada e em execução e task definition `:36`;
- RDS `laje-staging-postgres` PostgreSQL 17.9 estava disponível e privado;
- o RDS tinha retenção de backup de um dia, configuração Single-AZ e proteção contra exclusão desabilitada;
- os logs da API estavam no grupo `/laje/staging/api`.

Esse registro é uma fotografia do estado dos recursos, não uma validação funcional ou de publicação. Confirme também a execução correspondente do workflow `Deploy AWS`, health checks, smoke funcional e evidências de recuperação da versão apresentada.

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

## Justificativas e trade-offs preservados

- **Região:** `sa-east-1` é a região configurada e usada pelos recursos documentados. O ADR original não contém comparação quantitativa de latência ou custo entre regiões; este documento não atribui uma medição que não foi feita.
- **ECS/Fargate:** o runtime gerenciado evita administrar hosts EC2 e não mantém capacidade de instância ociosa quando o serviço está escalado a zero. Em contrapartida, ALB, VPC Link, API Gateway e recursos persistentes podem continuar gerando custo.
- **RDS PostgreSQL em vez de Aurora:** o PostgreSQL padrão atende à compatibilidade do schema e reduz complexidade e custo para o porte registrado no projeto. A configuração Single-AZ reduz custo e não oferece failover automático; retenção de backup de um dia e ausência de proteção contra exclusão também limitam a recuperação.
- **Um único RDS AWS para o TCC:** evita manter outro banco permanente e conserva a nomenclatura dos recursos existentes. O compartilhamento físico entre uso publicado e desenvolvimento exige separar os dados de teste. A base `laje_priority_flows` usada por testes não foi confirmada na instância, e os usuários sintéticos não são contas de homologação disponíveis.
- **Custo:** `aws:on` e `aws:off` controlam a tarefa ECS e o RDS, sem remover recursos. Não há estimativa mensal vigente neste ADR; valide preços e consumo atuais antes de estabelecer um valor.

## Decisões anteriores e atualização

A decisão original descrevia uma arquitetura futura com recursos AWS separados para integração e produção. A revisão da LAJE-37 documenta a alternativa implementada para o TCC: `laje-staging-postgres` é o único RDS selecionado para essa entrega, e o runtime atualmente nomeado como staging atende `laje-tcc`. Essa decisão não migra a operação permanente `laje` do Supabase nem declara concluído o cutover AWS de produção descrito no registro histórico NO-GO.

A auditoria de 15/10/2026 registrada no documento de release permanece como evidência histórica daquela data. Ela não define o estado atual nem exige uma infraestrutura paralela.

## Consequências

- Frontend, API e persistência do TCC têm um caminho de execução documentado e verificável.
- O mesmo RDS físico é compartilhado pelo frontend publicado e pelo desenvolvimento local via túnel SSM. Não há conta ou dataset de teste validado na AWS; testes de fluxo com escrita só podem usar uma base descartável/resetável `laje_priority_flows` depois de confirmada sua separação da base de demonstração.
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
