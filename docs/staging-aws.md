# Staging AWS da laje-api — LAJE-136

## Objetivo

Validar o caminho `frontend Vercel -> HTTPS -> laje-api AWS -> RDS PostgreSQL` sem alterar a produção atual no Supabase.

## Estado validado em 07/10/2026

A infraestrutura de staging está publicada e funcional em `sa-east-1`.

Evidências verificadas após o merge das correções AWS-only da LAJE-141:

- frontend de integração: `https://laje-tcc.vercel.app`;
- deployment Vercel: `READY`, baseado no commit `485aa1e6eb9b8e9fb4922c1dcd18d55712a4b603` do repositório `laje`;
- endpoint HTTPS da API: `https://zezxz6j7o1.execute-api.sa-east-1.amazonaws.com`;
- imagem em execução no ECS: `laje-staging-api:sha-b4f2d6517132`, correspondente ao commit `b4f2d6517132f2e6371b4c45bf297682284f65f7` da `main`;
- ECS service `laje-staging-api`: `1/1` task em execução, rollout concluído e health `HEALTHY`;
- task definition validada: `laje-staging-api:18`, Fargate `256 CPU / 512 MiB`;
- ECR `laje-staging-api`: tags imutáveis e scan-on-push habilitado;
- RDS `laje-staging-postgres`: PostgreSQL 17.9, status `available`, privado e criptografado;
- credenciais do banco e segredo JWT injetados por AWS Secrets Manager;
- CORS do API Gateway restrito a `https://laje-tcc.vercel.app`, com credenciais habilitadas;
- logs da API disponíveis em `/laje/staging/api` no CloudWatch, com retenção de 7 dias;
- bundle publicado do `laje-tcc` contém o endpoint AWS de staging e não contém referência a `supabase.co`.

O deploy mais recente validou:

- `GET /api/v1/health`: `{"service":"laje-api","status":"ok"}`;
- `GET /api/v1/health/database`: `{"database":"reachable","status":"ok"}`;
- CORS para o domínio do frontend de integração;
- CLV 2026;
- Society 2026;
- Interlaje 2026;
- 3 campeonatos;
- 442 jogos;
- 442 jogos com placar persistido;
- 36 W.O.s;
- contrato de W.O. presente nas 442 linhas testadas;
- 239 linhas de classificação retornadas pelos contratos de staging;
- 3 edições de chaveamento retornadas pelos contratos de staging;
- 19 competições de chaveamento.

Essas contagens são evidências funcionais do smoke E2E dos contratos públicos e não substituem o gate de paridade integral do cutover produtivo, que permanece na LAJE-139.

## Desenho de menor custo

```text
Vercel / cliente HTTP
        |
        | HTTPS
        v
API Gateway HTTP API (endpoint execute-api HTTPS)
        |
        | VPC Link privado
        v
Application Load Balancer interno
        |
        v
ECS/Fargate (1 x 0.25 vCPU / 512 MiB)
        |
        | PostgreSQL/TLS na VPC
        v
RDS PostgreSQL 17 privado
```

O Fargate usa as subnets públicas e `assign_public_ip=true` apenas para obter imagem do ECR e acessar APIs AWS sem NAT Gateway. O Security Group da task não aceita tráfego direto da Internet. O ALB é interno; o único caminho público é o endpoint HTTPS gerenciado pelo API Gateway, que alcança o listener do ALB por VPC Link.

## Segredos

O RDS continua gerando e armazenando a credencial master no Secrets Manager. A task definition injeta apenas as chaves `username` e `password` em variáveis de runtime. O JWT administrativo também é injetado por referência ao Secrets Manager. A aplicação constrói internamente a URL PostgreSQL, incluindo escaping de usuário/senha, e não imprime a URL.

Nenhuma credencial real deve ser adicionada à documentação, ao repositório ou aos artefatos de CI.

## Operação

O workflow `Deploy AWS` oferece:

- `deploy`: provisiona runtime, publica/reutiliza imagem imutável no ECR, inicia uma task e valida `/api/v1/health`, `/api/v1/health/database`, CORS e o smoke E2E;
- `suspend`: remove os componentes com cobrança contínua do runtime de staging.

O deploy usa GitHub Actions OIDC; não existem access keys AWS persistidas no GitHub.

Durante a fase atual, o deploy pode ser acionado manualmente para evitar religar recursos billable sem necessidade. A automação definitiva após merge na `main` pertence à LAJE-142 e não deve ser antecipada dentro da LAJE-136.

## Observabilidade

O runtime envia logs para o CloudWatch Logs no grupo:

```text
/laje/staging/api
```

A retenção configurada é de 7 dias. O container também possui healthcheck próprio contra `/api/v1/health`, além das validações externas executadas pelo pipeline.

## Controle de custo

- nenhum NAT Gateway;
- apenas uma task Fargate quando ativa;
- ALB/API Gateway VPC Link/ECS service removíveis por `staging_api_enabled=false`;
- ECR mantém no máximo três imagens;
- CloudWatch Logs retém sete dias;
- RDS staging continua sendo o componente persistente já existente e deve ser parado quando não estiver em uso, lembrando que o RDS pode reiniciar automaticamente após o limite de parada da AWS.

## Critérios de aceite da LAJE-136

- [x] `laje-api` responde em endpoint HTTPS de staging;
- [x] healthcheck da aplicação retorna sucesso;
- [x] healthcheck PostgreSQL retorna sucesso;
- [x] API usa o RDS privado de staging;
- [x] frontend `laje-tcc` consome a API AWS;
- [x] CORS/TLS validados;
- [x] credenciais permanecem fora do repositório;
- [x] smoke E2E cobre campeonato, jogos/placares/W.O., standings e bracket;
- [x] logs da API estão disponíveis no CloudWatch;
- [x] infraestrutura e deploy são reproduzíveis via Terraform/GitHub Actions;
- [x] Supabase de produção não foi alterado.

## Não é produção

Esta infraestrutura não executa o cutover produtivo. O ambiente legado baseado em Supabase continua separado até a LAJE-139.

O frontend `laje-tcc` existe para validar a arquitetura alvo. A hospedagem do frontend em Vercel permanece a exceção específica autorizada externamente para o projeto; backend, banco, infraestrutura e operação de staging permanecem na AWS.

## Decisão sobre HTTPS

A primeira tentativa de usar CloudFront como endpoint HTTPS foi rejeitada pela própria AWS porque a conta ainda exigia verificação adicional para novos recursos CloudFront. Para não depender de suporte manual nem manter o ALB exposto à Internet, o staging usa API Gateway HTTP API com endpoint `execute-api` gerenciado pela AWS e VPC Link para o ALB interno.
