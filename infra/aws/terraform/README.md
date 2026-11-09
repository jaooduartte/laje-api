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
- Amazon SQS, DLQ e EventBridge Scheduler para prévias assíncronas de chaveamento.

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

Em 09/11/2026, o plano de controle AWS mostrava o serviço ECS `laje-staging-api` com uma tarefa ativa, task definition `:36`, deployment concluído; o RDS `laje-staging-postgres` estava disponível em PostgreSQL 17.9. Consulte o [runbook do ambiente](../../../docs/staging-aws.md) e os health checks da execução de deploy antes de uma demonstração.

O frontend Vercel publicado e a API local conectada pelo túnel SSM usam esse mesmo RDS. A separação de uso local e publicado é lógica e deve preservar os dados históricos usados na demonstração, com contas/fixtures de homologação.

## Deploy pelo workflow

O workflow `Deploy AWS` executa o Terraform usando GitHub OIDC e o state remoto do ambiente. Na ação `deploy`, ele:

1. inicializa e valida a configuração Terraform;
2. prepara a infraestrutura AWS definida neste módulo;
3. publica ou reutiliza uma imagem imutável no ECR;
4. aplica as migrations operacionais no RDS selecionado para o TCC;
5. atualiza o serviço ECS/Fargate;
6. valida HTTPS, API, conexão PostgreSQL, CORS e smoke E2E.

O deploy é iniciado manualmente na branch `main`. Antes de iniciar, confira que a branch, o SHA da imagem e os parâmetros do ambiente correspondem à versão que será avaliada. Os arquivos `.tfvars`, state local, planos Terraform e valores de credenciais não devem ser commitados.

## Banco de dados

O baseline está em `infra/database/baseline/schema.sql`; alterações posteriores devem ser novas migrations em `infra/database/migrations/`. O RDS é privado. A aplicação de baseline ou migrations deve ocorrer pelo caminho de execução autorizado e nunca deve exigir liberar a porta `5432` para a Internet.

As credenciais do RDS são gerenciadas pelo AWS Secrets Manager. A configuração consultada usa backup automático com retenção de um dia; crie e confirme um snapshot manual antes de mudanças destrutivas e valide uma restauração em instância temporária privada antes de depender dela para recuperação. Não grave senhas, URLs de conexão com senha, tokens ou dados pessoais em arquivos do repositório, documentação ou comentários de PR.

## Validações de infraestrutura

O workflow Terraform valida formatação e configuração nas mudanças de infraestrutura. Antes de uma revisão de Terraform, use a versão indicada pela configuração do projeto e confira `terraform fmt -check` e `terraform validate`. O plano deve ser revisado antes de qualquer aplicação de infraestrutura.

## Referências

- [Arquitetura do LAJE TCC](../../../docs/architecture.md)
- [Publicação](../../../docs/deployment.md)
- [Runbook AWS](../../../docs/staging-aws.md)
- [Workflow de deploy](../../../.github/workflows/deploy-aws.yml)
