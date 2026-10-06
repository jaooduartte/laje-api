# Staging AWS da laje-api — LAJE-136

## Objetivo

Validar o caminho `frontend Vercel -> HTTPS -> laje-api AWS -> RDS PostgreSQL` sem alterar a produção atual no Supabase.

## Desenho de menor custo

```text
Vercel / cliente HTTP
        |
        | HTTPS
        v
CloudFront (certificado cloudfront.net)
        |
        | HTTP de origem, restrito ao prefix list da CloudFront
        v
Application Load Balancer
        |
        v
ECS/Fargate (1 x 0.25 vCPU / 512 MiB)
        |
        | PostgreSQL/TLS na VPC
        v
RDS PostgreSQL 17 privado
```

O Fargate usa as subnets públicas e `assign_public_ip=true` apenas para obter imagem do ECR e acessar APIs AWS sem NAT Gateway. O Security Group da task não aceita tráfego direto da Internet.

## Segredos

O RDS continua gerando e armazenando a credencial master no Secrets Manager. A task definition injeta apenas as chaves `username` e `password` em variáveis de runtime. A aplicação constrói internamente a URL PostgreSQL, incluindo escaping de usuário/senha, e não imprime a URL.

## Operação

O workflow `Deploy AWS` oferece:

- `deploy`: provisiona runtime, publica imagem ECR, inicia uma task e valida `/api/v1/health` e `/api/v1/health/database`;
- `suspend`: remove os componentes com cobrança contínua do runtime de staging.

O deploy usa GitHub Actions OIDC; não existem access keys AWS persistidas no GitHub.

## Controle de custo

- nenhum NAT Gateway;
- apenas uma task Fargate quando ativa;
- ALB/CloudFront/ECS service removíveis por `staging_api_enabled=false`;
- ECR mantém no máximo três imagens;
- CloudWatch Logs retém sete dias por padrão;
- RDS staging continua sendo o componente persistente já existente e deve ser parado quando não estiver em uso, lembrando que o RDS pode reiniciar automaticamente após o limite de parada da AWS.

## Não é produção

Esta infraestrutura não executa o cutover produtivo. Supabase continua sendo a produção até LAJE-139.
