# Publicação do LAJE TCC

## Escopo

Este documento descreve a publicação do frontend `laje-tcc` e da API `laje-api` na AWS para o Portfólio. O RDS `laje-staging-postgres` é o único banco AWS selecionado para essa entrega; os nomes dos recursos conservam a nomenclatura de staging.

O projeto Vercel `laje` permanece como produção operacional independente, com Supabase. A publicação AWS descrita aqui se aplica somente ao projeto Vercel `laje-tcc`; não migra nem altera a operação permanente.

| Componente | Projeto/serviço                        | Endereço atual                                                  |
| ---------- | -------------------------------------- | --------------------------------------------------------------- |
| Frontend   | Vercel `laje-tcc`                      | `https://laje-tcc.vercel.app`                                   |
| API        | API Gateway HTTP API em `sa-east-1`    | `https://rkckaptyaf.execute-api.sa-east-1.amazonaws.com/api/v1` |
| Runtime    | ECS/Fargate `laje-staging-api`         | Acesso interno pela API Gateway e ALB                           |
| Banco      | RDS PostgreSQL `laje-staging-postgres` | Privado na VPC; sem endpoint público                            |

Em 09/11/2026, a AWS reportou o serviço ECS com 1 tarefa em execução, deployment concluído e task definition `:36`; o RDS PostgreSQL 17.9 estava disponível. Confirme o estado nos health checks e na execução mais recente do workflow antes de uma demonstração.

O fluxo GitHub Actions/Terraform publica os recursos AWS usados pelo `laje-tcc`. O frontend Vercel e o desenvolvimento local conectado por túnel SSM usam o mesmo RDS. Os testes de fluxo que escrevem no banco exigem uma base denominada `laje_priority_flows`; não foi confirmada a existência dessa base na AWS. Contas sintéticas dos testes não são credenciais de homologação disponíveis no serviço publicado. Consulte o runbook antes de executar testes com escrita.

## CI

Os dois repositórios executam CI em pull requests e atualizações da branch `main`.

- Frontend: typecheck, lint, formatação, testes, builds e análise SonarQube Cloud.
- API: typecheck, lint, formatação, testes unitários e E2E, build, integração PostgreSQL, baseline/migrations, validação Docker e análise SonarQube Cloud.
- Terraform: formatação, lockfile e validação da infraestrutura nas mudanças correspondentes.

Os Quality Gates SonarQube Cloud estão ativos. Consulte os workflows dos repositórios para o resultado associado ao commit que será publicado.

## Publicar a API AWS do TCC

Workflow: `.github/workflows/deploy-aws.yml` (`workflow_dispatch`, branch `main`).

1. No repositório `laje-api`, abra GitHub Actions e selecione **Deploy AWS**.
2. Escolha a branch `main` e a ação `deploy`.
3. O workflow assume a role AWS por GitHub OIDC e inicializa o Terraform do ambiente TCC.
4. O Docker image recebe uma tag imutável `sha-<commit>` e é publicado/reutilizado no Amazon ECR.
5. O workflow aplica as migrations operacionais pendentes no RDS escolhido para a entrega e atualiza uma task Fargate do serviço `laje-staging-api`.
6. A publicação valida `GET /api/v1/health`, `GET /api/v1/health/database`, CORS para o domínio do `laje-tcc` e smoke E2E dos principais contratos.
7. Guarde a URL da execução, o SHA da imagem e os resultados dos health checks como evidência da versão publicada. Não registre segredos ou dados pessoais.

O workflow não é acionado automaticamente por merge ou push. Cada publicação deve ser identificada pela execução do GitHub Actions correspondente.

## Configuração do frontend Vercel

O projeto `laje-tcc` deve usar:

```text
VITE_BACKEND_PROVIDER=aws
VITE_API_URL=https://rkckaptyaf.execute-api.sa-east-1.amazonaws.com/api/v1
```

`VITE_*` é público e não deve conter tokens privados, credenciais de banco ou segredos de integração. A API Gateway permite a origem publicada `https://laje-tcc.vercel.app`; o desenvolvimento local deve usar o proxy Vite documentado na [Wiki de setup](https://github.com/jaooduartte/laje/wiki/Setup-e-Configura%C3%A7%C3%A3o-do-Ambiente).

## Configuração do backend

- A API usa variáveis privadas definidas pela task definition e segredos referenciados no AWS Secrets Manager.
- O RDS é privado e a aplicação conecta com TLS.
- A publicação usa GitHub OIDC; não crie access keys permanentes para o workflow.
- Migrations devem ser novas e versionadas. Não edite migrations já aplicadas.
- O workflow descrito aplica somente as migrations operacionais no RDS selecionado para o TCC.

## Evidências para uma entrega do Portfólio

Para comprovar uma versão publicada, registre:

- commit/SHA do frontend e da API;
- resultado dos workflows CI e Quality Gate;
- deployment Vercel do `laje-tcc`;
- execução do workflow `Deploy AWS` e tag imutável da imagem;
- health da API, health do PostgreSQL, CORS e smoke E2E;
- validação funcional do fluxo público e administrativo na versão publicada.

O nome `staging` no ECS, no RDS e em variáveis Terraform não exige um segundo RDS para a entrega. Registre as evidências do commit, deployment, health checks e fluxo funcional da versão apresentada.

## Referências

- [Arquitetura do LAJE TCC](./architecture.md)
- [Runbook AWS](./staging-aws.md)
- [Terraform](../infra/aws/terraform/README.md)
- [CI](../.github/workflows/ci.yml)
- [Deploy AWS](../.github/workflows/deploy-aws.yml)
