# Ambiente AWS do LAJE TCC

## Escopo

Este runbook descreve o ambiente AWS que atende o frontend `laje-tcc` e a entrega do Portfólio. O projeto Vercel `laje` permanece na operação permanente com Supabase e não é afetado por estes procedimentos. O runtime, o banco e algumas variáveis mantêm o prefixo `staging`; o RDS `laje-staging-postgres` é o único banco AWS escolhido para a entrega.

## Estado verificado em 09/11/2026

| Recurso              | Estado consultado                                                                                                                       |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Região               | `sa-east-1`                                                                                                                             |
| API Gateway HTTP API | `rkckaptyaf`, estágio `$default`, endpoint `https://rkckaptyaf.execute-api.sa-east-1.amazonaws.com`                                     |
| Rota pública         | `$default`, integrada como `HTTP_PROXY` pelo VPC Link `jxvnnl`                                                                          |
| ALB                  | `laje-staging-api`, interno                                                                                                             |
| ECS                  | Serviço `laje-staging-api` ativo, 1 tarefa desejada e em execução, task definition `:36`                                                |
| RDS                  | `laje-staging-postgres`, PostgreSQL 17.9, `available`, privado, backup com retenção de um dia, Single-AZ e sem proteção contra exclusão |
| Origem CORS          | `https://laje-tcc.vercel.app`                                                                                                           |
| Logs                 | CloudWatch Logs, grupo `/laje/staging/api`                                                                                              |

O status acima foi consultado no plano de controle AWS. Para comprovar que uma versão da aplicação está pronta para uso, consulte os health checks e o smoke E2E da execução mais recente de `Deploy AWS`.

O frontend publicado e o desenvolvimento local da API usam a mesma instância RDS. A diferença entre os fluxos está nos endpoints e no acesso: o público passa pela API Gateway e o local pelo túnel SSM. A consulta confirma o estado do plano de controle, não a saúde dos endpoints, a execução do workflow ou a validação funcional.

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

## Isolamento dos testes no RDS compartilhado

Os testes de fluxo em `tests/flows/priority-flows.test.ts` e `tests/flows/championship-reconfiguration.test.ts` verificam se `DATABASE_URL` contém `laje_priority_flows`. Essa verificação examina o texto da URL; não comprova que o hostname ou a base PostgreSQL sejam isolados da aplicação publicada. Os testes criam registros sintéticos com IDs fixos e contas temporárias, incluindo `laje38-ci` e `laje150-ci`, com e-mails do domínio reservado `example.invalid`.

Essas contas não são provisionadas no serviço AWS. A revisão estática não encontrou limpeza dos registros ao final desses testes. A lista de bancos dentro do RDS não foi consultada; portanto, não está comprovado que exista uma base isolada `laje_priority_flows` na AWS. A base de aplicação usada pela demonstração e os registros que podem ser usados com segurança não foram identificados.

Execute testes de fluxo com escrita somente em uma base descartável ou resetável, após confirmar o `DATABASE_URL`, hostname e nome da base. Não aponte esses testes à base usada pela demonstração ou pelo deployment `laje-tcc`. Até a existência e o isolamento de uma base de teste serem comprovados, limite a validação a checks sem escrita ou ambientes locais efêmeros. Não crie bancos, contas ou fixtures no RDS sem autorização específica.

## Backup, restauração e rollback

O RDS tem backups automáticos com retenção configurada de um dia. A proteção contra exclusão não estava habilitada no estado consultado em 09/11/2026; confirme o estado atual antes de uma mudança destrutiva.

Antes de alterar schema ou remover dados:

1. registre commit da API, task definition e objetivo da mudança;
2. crie um snapshot manual com identificador contendo data e motivo;
3. confira que o snapshot terminou com sucesso antes de prosseguir.

Para recuperar dados, restaure o snapshot para uma instância temporária privada, dentro da VPC e com Security Group restrito. Valide migrations, integridade e fluxos de leitura em um contexto isolado. Só depois da revisão da recuperação avalie uma troca controlada do endpoint usado pela API. A instância temporária é um recurso de recuperação; não é requisito de um segundo RDS permanente.

Para reverter uma publicação sem mudança incompatível de schema, publique novamente a imagem ECR imutável anterior. Se houver escritas posteriores ao snapshot, avalie a perda de dados e a forma de reconciliação antes de qualquer restauração; não substitua o RDS ativo sem plano e aprovação específicos.

O fluxo atual não documenta um ensaio de restauração concluído. Registre a execução, os responsáveis e os resultados antes de tratar o procedimento como validado.

## Suspender e reativar recursos por custo

Os comandos abaixo alteram recursos billable. Antes de executá-los, confirme que a identidade AWS ativa corresponde a `AWS_EXPECTED_ACCOUNT_ID` do `.env`. Os comandos não criam nem removem recursos.

Na raiz de `laje-api`, para ligar o RDS se estiver parado, definir uma tarefa ECS e aguardar os estados prontos:

```bash
npm run aws:on
```

Para desligar o serviço ECS e parar o RDS:

```bash
npm run aws:off
```

O script valida a conta AWS configurada. `aws:on` inicia o RDS caso necessário, define `desiredCount=1` no serviço ECS e aguarda estabilização. Ele grava um override manual de 12 horas para impedir que a agenda noturna desligue uma sessão iniciada manualmente. `dev:aws` renova esse override enquanto o túnel estiver ativo. `aws:off` remove o override, sinaliza o worker SQS para parar de buscar novas mensagens, aguarda o trabalho corrente, reduz o ECS a zero e verifica o encerramento das tasks antes de parar o RDS. Se a drenagem ou o encerramento gracioso não forem confirmados, o RDS permanece ligado. O lock DynamoDB compartilhado serializa esses comandos com a rotação de credenciais, o deploy e as agendas.

A API Gateway, o VPC Link, o ALB e outros recursos provisionados permanecem; desligar ECS e RDS não elimina todos os custos AWS. Enquanto o RDS está parado, a AWS continua cobrando armazenamento e backups retidos; consulte a documentação de [parada temporária do RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html).

Confirme o estado do banco:

```bash
aws rds describe-db-instances --db-instance-identifier laje-staging-postgres --region sa-east-1 --query 'DBInstances[0].DBInstanceStatus' --output text
```

Confirme o serviço e as tasks ECS:

```bash
aws ecs describe-services --cluster laje-staging-api --services laje-staging-api --region sa-east-1 --query 'services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}' --output table
aws ecs list-tasks --cluster laje-staging-api --service-name laje-staging-api --region sa-east-1
```

Depois de ligar, espere RDS `available`, ECS com `desired=1` e `running=1`, e confirme `/api/v1/health` e `/api/v1/health/database`. Esses sinais não comprovam os fluxos de produto; execute e registre o smoke funcional da versão a apresentar. Depois de desligar, confirme RDS `stopped`, ECS `desired=0` e `running=0`, sem tasks retornadas. A AWS pode reiniciar uma instância RDS após sete dias consecutivos parada.

Para desenvolvimento local com `npm run dev:aws`, mantenha o terminal do túnel SSM ativo e execute `npm run dev` em outro terminal para iniciar a API local. Ao terminar, interrompa primeiro a API local e finalize o túnel com `Ctrl+C`. O script fecha o túnel e interrompe somente os recursos que iniciou naquela sessão. Se a sessão SSM terminar inesperadamente ou os recursos já estivessem ativos antes, confira ECS e RDS e use `npm run aws:off` ao fim da janela de uso.

## LAJE-152: automação de custo e operação

As mudanças desta tarefa ficam no ambiente AWS do TCC. O Vercel `laje`, o caminho Supabase e o contrato da API não são alterados.

O Terraform define agendas EventBridge Scheduler diárias para desligar às 00h e iniciar às 09h no fuso `America/Sao_Paulo`. `staging_automation_schedules_enabled` permanece `false` por padrão. A janela de 00h a 09h representa indisponibilidade planejada. O início às 09h não garante disponibilidade nesse horário: o RDS pode levar tempo para iniciar e a API só é considerada pronta após ECS estável e verificações HTTP bem-sucedidas.

Para habilitar as agendas, a configuração externa deve fornecer `STAGING_AUTOMATION_ALERT_EMAIL` e marcar `STAGING_AUTOMATION_ALERT_EMAIL_CONFIRMED=true` somente depois de aceitar a confirmação enviada pelo SNS. O endereço não fica no repositório. O workflow valida essas condições antes de qualquer aplicação Terraform.

A máquina de estados serializa as operações pelo mesmo item de lock DynamoDB usado pela rotação RDS, pelos comandos locais e pelo workflow de deploy. No desligamento, o worker confirma drenagem, o ECS chega a zero e as tasks encerram com sucesso antes do RDS ser parado. A confirmação de `STOPPED` permite até 12 novas tentativas com intervalos de 15 segundos, para aguardar a finalização da task após o serviço ECS chegar a zero. A automação também espera o RDS sair de `backing-up` antes de iniciar ou parar o banco. A janela de backup observada no ambiente atual é 00h–01h em São Paulo. Se a task continuar ativa, encerrar com código diferente de zero ou ocorrer falha na drenagem ou em uma etapa anterior ao pedido de parada, o RDS permanece ligado e uma notificação SNS é enviada. Se houver falha durante a espera após a AWS aceitar o pedido de parada do RDS, o estado pode ser `stopping` ou `stopped`; consulte o plano de controle antes de qualquer nova ação. O DLQ de agendamento também tem alarme CloudWatch.

A inicialização espera o RDS `available`, estabiliza uma task ECS e consulta `/api/v1/health`, `/api/v1/health/database` e `/api/v1/public/settings`. O horário real de prontidão é registrado no CloudWatch. Mensagens ainda não iniciadas permanecem na fila SQS.

Cloud Map é somente uma opção de canário: `staging_api_cloud_map_enabled` e `staging_api_use_cloud_map` permanecem `false`. A rota principal continua no ALB; a rota canário exige AWS IAM. API Gateway, VPC Link e ALB existentes não são removidos, e nenhum corte deve ocorrer antes dos testes e da comparação de custo. Recursos de API Gateway sem rotas e VPC Links adicionais ainda exigem confirmação de propriedade; não devem ser importados ou removidos por esta mudança.

A [LAJE-152](https://joaoduartte.atlassian.net/browse/LAJE-152) registra como referência histórica aproximada de outubro de 2026 RDS US$ 29,68, ALB US$ 21,22 e ECS/Fargate US$ 12,73, antes de créditos e ajustes; esses valores não são o custo líquido atual nem foram atualizados nesta execução pelo Cost Explorer. A comparação financeira deve usar outubro como mês fechado, separar consumo faturável e créditos e projetar 30 e 45 dias e até 16 de dezembro, incluindo Step Functions, Lambda, Scheduler, CloudWatch e Cloud Map. Como as agendas e o canário permanecem desativados nesta entrega, ainda não há economia realizada para reportar. A redução efetiva só pode ser confirmada depois de ciclos controlados e da comparação pós-ativação.

## Referências

- [Arquitetura](./architecture.md)
- [Publicação](./deployment.md)
- [Terraform AWS](../infra/aws/terraform/README.md)
- [Workflow de deploy](../.github/workflows/deploy-aws.yml)
