# Ambiente AWS do LAJE TCC

## Escopo

Este runbook descreve o ambiente AWS que atende o frontend `laje-tcc` e a entrega do Portfólio. O runtime, o banco e algumas variáveis mantêm o prefixo `staging`; o RDS `laje-staging-postgres` é o único banco AWS escolhido para a entrega.

## Estado verificado em 09/11/2026

| Recurso              | Estado consultado                                                                                                  |
| -------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Região               | `sa-east-1`                                                                                                        |
| API Gateway HTTP API | `rkckaptyaf`, estágio `$default`, endpoint `https://rkckaptyaf.execute-api.sa-east-1.amazonaws.com`                |
| Rota pública         | `$default`, integrada como `HTTP_PROXY` pelo VPC Link `jxvnnl`                                                     |
| ALB                  | `laje-staging-api`, interno                                                                                        |
| ECS                  | Cluster e serviço `laje-staging-api`; 1 tarefa desejada e em execução; task definition `:36`, deployment concluído |
| RDS                  | `laje-staging-postgres`, PostgreSQL 17.9, `available`, privado, criptografado e com TLS obrigatório                |
| Origem CORS          | `https://laje-tcc.vercel.app`                                                                                      |
| Logs                 | CloudWatch Logs, grupo `/laje/staging/api`                                                                         |

O status acima foi consultado no plano de controle AWS. Para comprovar que uma versão da aplicação está pronta para uso, consulte os health checks e o smoke E2E da execução mais recente de `Deploy AWS`.

O frontend publicado e o desenvolvimento local da API usam a mesma instância RDS. A diferença entre os fluxos está nos endpoints e no acesso: o público passa pela API Gateway e o local pelo túnel SSM. A homologação deve usar contas e fixtures de teste que não alterem os dados históricos da demonstração.

## Topologia

```text
Vercel: laje-tcc
   | HTTPS /api/v1
   v
API Gateway HTTP API (endpoint execute-api)
   | VPC Link / HTTP proxy
   v
ALB interno
   v
ECS/Fargate: laje-api
   | PostgreSQL com TLS
   v
RDS privado: PostgreSQL 17
```

O endpoint público de API Gateway encaminha tráfego ao ALB interno usando o VPC Link. A task Fargate usa subnet pública e IP para saída; seu Security Group não permite entrada direta da Internet e aceita tráfego da API por meio do ALB. O RDS permanece em subnet privada e não é publicamente acessível.

## Saúde e configuração

O deploy valida:

```text
GET /api/v1/health
GET /api/v1/health/database
```

Também valida CORS para `https://laje-tcc.vercel.app` e executa o smoke E2E dos contratos centrais. O health check do target group do ALB usa `/api/v1/health`.

O frontend publicado usa:

```text
VITE_BACKEND_PROVIDER=aws
VITE_API_URL=https://rkckaptyaf.execute-api.sa-east-1.amazonaws.com/api/v1
```

Essas variáveis são públicas no bundle e não podem conter credenciais. Segredos da API são obtidos do AWS Secrets Manager por referências da task definition.

## Deploy da API

O workflow `.github/workflows/deploy-aws.yml` é acionado manualmente na branch `main`. Ele autentica no AWS com GitHub OIDC, valida Terraform, publica uma imagem imutável no ECR, aplica as migrations operacionais no RDS escolhido para o TCC, atualiza uma task ECS e roda health checks, validação CORS e smoke E2E.

O workflow usa variáveis e secrets configurados no GitHub Actions para parâmetros de operação. Nenhum valor de segredo deve ser copiado para este documento, para o bundle do frontend ou para arquivos versionados.

## Desenvolvimento local com o RDS AWS

Use `.env.example` como lista das variáveis locais esperadas. Preencha os valores necessários no `.env` local, sem copiá-los para o repositório.

O script existente `npm run dev:aws` verifica a conta esperada, prepara a conexão pelo AWS Systems Manager Session Manager e abre o túnel para o RDS em `127.0.0.1:15432`. São necessários AWS CLI, Session Manager Plugin, identidade AWS válida e permissões do ambiente.

Em outro terminal, execute `npm run dev` para iniciar a API local. Configure o frontend local para encaminhar `/api/v1` ao endereço da API local (`http://localhost:3100`) ou ao endpoint AWS, conforme o fluxo escolhido. A configuração detalhada está na [Wiki de setup](https://github.com/jaooduartte/laje/wiki/Setup-e-Configura%C3%A7%C3%A3o-do-Ambiente).

O banco é compartilhado entre desenvolvimento local e frontend publicado do TCC. Use somente contas e registros de homologação identificáveis e preserve os dados históricos da demonstração. Não execute migrations ou operações de escrita remota sem autorização específica.

## Backup, restauração e rollback

O RDS tem backups automáticos com retenção configurada de um dia. A proteção contra exclusão não estava habilitada no estado consultado em 09/11/2026; confirme o estado atual antes de uma mudança destrutiva.

Antes de alterar schema ou remover dados:

1. registre commit da API, task definition e objetivo da mudança;
2. crie um snapshot manual com identificador contendo data e motivo;
3. confira que o snapshot terminou com sucesso antes de prosseguir.

Para recuperar dados, restaure o snapshot para uma instância temporária privada, dentro da VPC e com Security Group restrito. Valide migrations, integridade e fluxos de leitura em um contexto isolado. Só depois da revisão da recuperação avalie uma troca controlada do endpoint usado pela API. A instância temporária é um recurso de recuperação; não é requisito de um segundo RDS permanente.

Para reverter uma publicação sem mudança incompatível de schema, publique novamente a imagem ECR imutável anterior. Se houver escritas posteriores ao snapshot, avalie a perda de dados e a forma de reconciliação antes de qualquer restauração; não substitua o RDS ativo sem plano e aprovação específicos.

O fluxo atual não documenta um ensaio de restauração concluído. Registre a execução, os responsáveis e os resultados antes de tratar o procedimento como validado.

## Referências

- [Arquitetura](./architecture.md)
- [Publicação](./deployment.md)
- [Terraform AWS](../infra/aws/terraform/README.md)
- [Workflow de deploy](../.github/workflows/deploy-aws.yml)
