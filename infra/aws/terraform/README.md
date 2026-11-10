# Infraestrutura AWS do LAJE TCC

## Escopo

Este módulo Terraform provisiona os recursos AWS usados pelo frontend `laje-tcc` e pela API `laje-api`, na região `sa-east-1`. O RDS `laje-staging-postgres` é o único banco AWS selecionado para a entrega; o prefixo `staging` permanece nos identificadores Terraform.

O estado gerenciado pelo módulo inclui:

- VPC e subnets distribuídas em duas zonas de disponibilidade;
- Security Groups para o tráfego entre ALB, tasks ECS e RDS;
- Amazon RDS for PostgreSQL 17 com armazenamento criptografado, backups e TLS obrigatório;
- Amazon ECR com scan-on-push e tags imutáveis;
- ECS/Fargate para executar a API e o worker;
- ALB interno e API Gateway HTTP API com VPC Link;
- CloudWatch Logs e alarmes para recursos monitorados;
- AWS Secrets Manager e papéis IAM para segredos e acesso dos serviços;
- Amazon SQS, DLQ e EventBridge Scheduler para prévias assíncronas de chaveamento;
- AWS Step Functions, Lambda e EventBridge Scheduler para o ciclo operacional do RDS/ECS, com as agendas noturnas desabilitadas por padrão;
- Amazon Cloud Map opcional para um canário da API, mantendo o caminho pelo ALB como padrão.

## Fluxo de rede

```text
Vercel laje-tcc
  -> HTTPS /api/v1
  -> API Gateway HTTP API
  -> VPC Link
  -> ALB interno
  -> ECS/Fargate laje-api
  -> RDS PostgreSQL privado com TLS
```

O RDS não é público e aceita conexões PostgreSQL somente dos Security Groups previstos. O ALB também é interno. A task Fargate usa subnet pública e IP para comunicação de saída com serviços AWS; o Security Group não permite entrada direta da Internet.

## Estado consultado

Consulta de somente leitura ao plano de controle AWS em 09/11/2026 mostrou o serviço ECS `laje-staging-api` com uma tarefa ativa, task definition `:36`, e o RDS `laje-staging-postgres` disponível em PostgreSQL 17.9. Isso não comprova health checks ou fluxos da aplicação; consulte o [runbook do ambiente](../../../docs/staging-aws.md) e a execução de deploy antes de uma demonstração.

O frontend Vercel `laje-tcc` e a API local conectada pelo túnel SSM usam esse mesmo RDS. Os testes de fluxo exigem uma URL `DATABASE_URL` que contenha `laje_priority_flows`, mas a base não foi confirmada na AWS e seus usuários sintéticos não são contas de homologação no serviço publicado. Não execute testes de escrita contra os dados de demonstração; os detalhes estão no [runbook](../../../docs/staging-aws.md#isolamento-dos-testes-no-rds-compartilhado).

## Deploy pelo workflow

O workflow `Deploy AWS` executa o Terraform usando GitHub OIDC e o state remoto do ambiente. Na ação `deploy`, ele:

1. inicializa e valida a configuração Terraform;
2. prepara a infraestrutura AWS definida neste módulo;
3. publica ou reutiliza uma imagem imutável no ECR;
4. aplica as migrations operacionais no RDS selecionado para o TCC;
5. atualiza o serviço ECS/Fargate;
6. valida HTTPS, API, conexão PostgreSQL, CORS e smoke E2E.

O deploy é iniciado manualmente na branch `main`. Antes de iniciar, confira que a branch, o SHA da imagem e os parâmetros do ambiente correspondem à versão que será avaliada. Os arquivos `.tfvars`, state local, planos Terraform e valores de credenciais não devem ser commitados.

O workflow adquire o lock compartilhado do serviço antes de alterar a infraestrutura ou executar migrations e o libera ao finalizar. As operações locais `aws:on`, `aws:off` e `dev:aws`, a rotação RDS e a máquina de estados usam o mesmo lock.

## Banco de dados

O baseline está em `infra/database/baseline/schema.sql`; alterações posteriores devem ser novas migrations em `infra/database/migrations/`. O RDS é privado. A aplicação de baseline ou migrations deve ocorrer pelo caminho de execução autorizado e nunca deve exigir liberar a porta `5432` para a Internet.

As credenciais do RDS são gerenciadas pelo AWS Secrets Manager. A configuração consultada usa backup automático com retenção de um dia; crie e confirme um snapshot manual antes de mudanças destrutivas e valide uma restauração em instância temporária privada antes de depender dela para recuperação. Não grave senhas, URLs de conexão com senha, tokens ou dados pessoais em arquivos do repositório, documentação ou comentários de PR.

## Validações de infraestrutura

O workflow Terraform valida formatação e configuração nas mudanças de infraestrutura. Antes de uma revisão de Terraform, use a versão indicada pela configuração do projeto e confira `terraform fmt -check` e `terraform validate`. O plano deve ser revisado antes de qualquer aplicação de infraestrutura.

## LAJE-152: ciclo de disponibilidade

As agendas de desligamento às 00h e inicialização às 09h usam o fuso `America/Sao_Paulo`, sem janela flexível, e permanecem `DISABLED` enquanto `staging_automation_schedules_enabled=false`. A validação Terraform exige endereço SNS externo e confirmação manual da assinatura antes de habilitar as agendas.

A máquina de estados usa o item de lock do serviço ECS na tabela DynamoDB existente de rotação. O desligamento grava um pedido de drenagem, aguarda o worker SQS confirmar que não há trabalho corrente, reduz o ECS a zero, valida o encerramento das tasks e só então para o RDS. A inicialização aguarda RDS `available`, uma task ECS estável e os endpoints de health e rota pública segura. Falhas geram notificações SNS e são registradas no CloudWatch.

O desligamento diário causa indisponibilidade planejada entre 00h e 09h. O horário das 09h inicia o processo, não promete que o banco ou a API estarão prontos exatamente nesse instante.

`staging_api_cloud_map_enabled=false` mantém Cloud Map fora do plano padrão. Quando habilitado para canário, a rota AWS IAM é adicional e a rota principal continua no ALB. `staging_api_use_cloud_map` só pode ser considerado após testes funcionais e comparação de custo. O plano desta tarefa não importa nem remove API Gateways sem rotas, VPC Links adicionais ou o ALB.

O texto da [LAJE-152](https://joaoduartte.atlassian.net/browse/LAJE-152) registra como referência histórica aproximada de outubro de 2026 RDS US$ 29,68, ALB US$ 21,22 e ECS/Fargate US$ 12,73, antes de créditos e ajustes; esses valores não representam custo líquido atual e não foram atualizados nesta execução pelo Cost Explorer. O baseline deve separar cobranças de uso e créditos, e incluir os serviços adicionados pela automação. A economia líquida não pode ser declarada enquanto as agendas estiverem desabilitadas e não houver comparação pós-ativação.

## Referências

- [Arquitetura do LAJE TCC](../../../docs/architecture.md)
- [Publicação](../../../docs/deployment.md)
- [Runbook AWS](../../../docs/staging-aws.md)
- [Workflow de deploy](../../../.github/workflows/deploy-aws.yml)
