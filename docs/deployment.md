# CI/CD multi-repositório — LAJE-33

## Escopo e situação

A aplicação é dividida entre dois repositórios independentes: `jaooduartte/laje` (frontend React/Vite na Vercel) e `jaooduartte/laje-api` (API Node.js/Express na AWS). O banco de dados do estado-alvo é Amazon RDS PostgreSQL 17.

Enquanto a LAJE-139 não concluir o cutover, a produção operacional permanece no Supabase. O projeto Vercel `laje-tcc` consome a API AWS de staging; o projeto `laje` continua no backend legado.

Esta entrega consolida os contratos de CI/CD e a operação segura de staging. **Não habilita deploy produtivo automático, não provisiona RDS de produção e não troca o tráfego atual.** O deploy automático após merge em `main` foi deliberadamente reservado à LAJE-142.

## CI por pull request

No frontend (`laje/.github/workflows/ci.yml`), `pull_request -> main` e `push -> main` executam typecheck, lint, Prettier incremental, testes e builds separados para Supabase e AWS-only.

No backend (`.github/workflows/ci.yml`), `pull_request -> main` e `push -> main` executam typecheck, lint, Prettier, testes unitários e E2E, build, testes de integração PostgreSQL 17, validação do baseline/migrations e validação da imagem Docker quando os arquivos relevantes forem alterados. A pipeline `.github/workflows/terraform.yml` verifica formatação, lockfile e `terraform validate` em PRs que alterem a infraestrutura.

Aprovação do CI e revisão por pares devem ocorrer **antes do merge**. A execução pós-merge é uma evidência adicional, não um mecanismo para bloquear um merge já executado.

## Staging AWS: deploy controlado

Workflow: `.github/workflows/deploy-aws.yml` (**somente `workflow_dispatch` na `main`**).

1. No GitHub Actions do repositório `laje-api`, selecione **Deploy AWS** e a branch `main`.
2. Escolha `action=deploy` para iniciar/atualizar o staging ou `action=suspend` para desligar o runtime com custo contínuo.
3. O deploy utiliza GitHub OIDC e a role `laje-github-actions-staging-deploy`; não usa chaves AWS estáticas.
4. Terraform valida/aplica a infraestrutura de staging; a imagem Docker é publicada no ECR com tag `sha-<commit>` imutável.
5. Uma task efêmera aplica migrations operacionais no RDS staging; depois o serviço ECS/Fargate inicia e a API é validada via HTTPS, health do PostgreSQL, CORS e smoke E2E.
6. Registre URL do workflow, SHA da imagem, endpoint e resultado dos testes na PR/Jira. Não registre senhas, tokens ou dados pessoais.
7. Ao terminar a validação, execute `action=suspend` e confirme os recursos desligados.

O gatilho automático antigo da branch `LAJE-136` foi removido para impedir reprovisionamento acidental. O fluxo não é acionado por PR nem por push. A LAJE-142 definirá futuramente o gatilho de `main`, filtros de paths, condições de custo e o comportamento de reativação do staging.

## Configuração de ambientes e segurança

Frontend Vercel:

- `laje`: `VITE_BACKEND_PROVIDER=supabase`, com URL e chave publicável do Supabase.
- `laje-tcc`: `VITE_BACKEND_PROVIDER=aws` e `VITE_API_URL=<url-https-da-api>/api/v1`, sem inicialização do cliente Supabase.
- Variáveis `VITE_*` são públicas e não podem conter secrets.

Backend AWS:

- Staging usa OIDC, AWS Secrets Manager, variável `CORS_ORIGINS=https://laje-tcc.vercel.app` e Terraform state específico de staging.
- Senhas de PostgreSQL, JWT e Brevo ficam fora do GitHub e do bundle Vite. O RDS é privado e exige TLS.
- Para futura produção, usar role OIDC, Secrets Manager, estado Terraform, ambientes e credenciais **distintos** dos de staging.
- A origem permitida em produção deve ser o domínio do frontend efetivamente promovido; não liberar `*` com credenciais.

O pipeline não deve executar migrações de dados produtivos automaticamente. Mudanças de schema devem ser novas migrations versionadas; não editar migrations já aplicadas.

## Gates do futuro release produtivo

Antes de configurar o deployment de produção e trocar o frontend, exigir:

1. LAJE-89 (realtime) e LAJE-126 (workloads) concluídas e testadas, além das dependências descritas em LAJE-139.
2. CI/quality gate aprovado nos dois repositórios, revisão por pares e SHA/versionamento rastreável.
3. Terraform `plan` de produção revisado, estimativa de custo aprovada, credenciais e infraestrutura segregadas, backup/snapshot e rollback preparado.
4. Write freeze efetivo na origem, sincronização/paridade finais da LAJE-139 e migrations validadas.
5. Deploy da API produtiva com imagem imutável ECR, aprovação manual de promoção, ECS saudável, health PostgreSQL, CORS e smoke E2E.
6. Atualização controlada das variáveis do frontend Vercel e novo build, validação funcional e observabilidade; somente então promover tráfego.
7. Plano de reversão compatível com a existência de escritas no banco novo, incluindo decisão explícita sobre reversão de dados. Reverter apenas a versão da aplicação não reverte dados.

Não considerar a LAJE-33 concluída antes de existirem evidências de deploy funcional no estado-alvo e documentação de publicação atualizada.

## Referências

- [Staging e validação AWS](./staging-aws.md)
- [Arquitetura e decisões de infraestrutura](./architecture.md)
- [Terraform AWS](../infra/aws/terraform/README.md)
- [Jira LAJE-33](https://joaoduartte.atlassian.net/browse/LAJE-33)
- [Jira LAJE-142](https://joaoduartte.atlassian.net/browse/LAJE-142)
- [Jira LAJE-139](https://joaoduartte.atlassian.net/browse/LAJE-139)

A documentação pública final deve também ser refletida na Wiki do projeto antes da entrega do TCC.
