# LAJE-139 — Publicação do ambiente TCC `laje-tcc`

## Escopo atual

Este documento registra a arquitetura e a publicação da versão web do TCC. O frontend Vercel `laje-tcc` usa a `laje-api` na AWS e o único RDS PostgreSQL selecionado para a entrega, `laje-staging-postgres`. Os nomes AWS conservam o prefixo `staging`; eles não indicam que exista ou seja necessário um segundo banco para a publicação. O projeto Vercel `laje` permanece na produção operacional da LAJE com Supabase; a seleção de um RDS para o TCC não muda esse ambiente.

O frontend publicado e o desenvolvimento local da API pelo túnel SSM usam a mesma instância RDS. A revisão encontrou fixtures de fluxo que exigem uma URL de conexão contendo `laje_priority_flows`, mas não confirmou a existência dessa base na AWS. As contas sintéticas dos testes não são provisionadas no ambiente publicado e não há prova de que contas administrativas isolem registros de demonstração. Não use a base da demonstração para testes de escrita.

## Auditoria AWS de 09/11/2026

Na consulta da conta AWS em `sa-east-1`:

- API Gateway HTTP API `rkckaptyaf` encaminhava a rota `$default` por VPC Link a um ALB interno;
- o serviço ECS/Fargate `laje-staging-api` estava com uma tarefa desejada e em execução, deployment concluído e task definition `:36`;
- o RDS `laje-staging-postgres` PostgreSQL 17.9 estava disponível, privado, criptografado e em Single-AZ;
- os logs da API eram enviados para `/laje/staging/api`;
- o frontend publicado usava a origem CORS `https://laje-tcc.vercel.app`.

Esta auditoria é uma fotografia do ambiente naquela data. Confirme o deployment, os health checks e o fluxo funcional da versão que será apresentada.

## Registro histórico da auditoria de 15/10/2026

O registro **NO-GO** de 15/10/2026 pertence à proposta de migração da operação permanente `laje` do Supabase para uma infraestrutura AWS de produção separada. A decisão da LAJE-37 de usar `laje-staging-postgres` para o deployment TCC resolve o escopo de hospedagem acadêmica sem criar um segundo RDS; ela não altera o backend Supabase de `laje`, não encerra a avaliação NO-GO daquela migração e não comprova prontidão funcional ou de recuperação do ambiente TCC.

Para declarar a versão TCC pronta para apresentação, valide separadamente a execução de publicação, health checks, smoke funcional dos fluxos apresentados, backups e um ensaio de restauração. A consulta ao estado ECS/RDS, isoladamente, não atende esses critérios. O ensaio de restauração ainda não foi comprovado nesta revisão.

Revisões antigas deste arquivo também descreviam infraestrutura futura e gates de migração que não correspondem à publicação documentada aqui. A evidência da auditoria antiga não deve ser usada como retrato do runtime atual.

## Configuração do frontend

O projeto Vercel `laje-tcc` deve ser compilado com:

```text
VITE_BACKEND_PROVIDER=aws
VITE_API_URL=https://rkckaptyaf.execute-api.sa-east-1.amazonaws.com/api/v1
```

`VITE_*` é incorporado ao bundle durante o build e é público. Qualquer alteração exige um novo deployment do projeto `laje-tcc`. Não coloque segredos ou credenciais nessas variáveis.

## Desenvolvimento local

Para usar a API AWS localmente, o comando existente `npm run dev:aws` abre um túnel SSM para o RDS privado em `127.0.0.1:15432`. Em outro terminal, `npm run dev` inicia a API local. O frontend local pode usar o proxy Vite para encaminhar chamadas à API local ou ao endpoint público.

O túnel e o runtime local acessam o mesmo RDS usado pela versão publicada. Use dados de teste identificáveis, evite operações destrutivas e preserve os dados históricos da demonstração.

## Processo de publicação

1. Identifique o commit do frontend e da API que compõem a versão avaliada.
2. Confirme no projeto Vercel `laje-tcc` as variáveis AWS acima e o deployment concluído.
3. Acione manualmente o workflow `Deploy AWS` da `laje-api`, na branch `main`, para o commit selecionado.
4. Confirme a imagem imutável publicada no ECR, a conclusão do deployment ECS e a task ativa.
5. Valide HTTPS, `/api/v1/health`, `/api/v1/health/database`, CORS e smoke dos fluxos funcionais apresentados.
6. Registre os SHAs, o deployment Vercel, a execução do workflow AWS e os resultados dos health checks e smoke.

O workflow valida Terraform, publica ou reutiliza a imagem identificada pelo commit, aplica migrations operacionais no RDS selecionado para o TCC, atualiza o serviço ECS e executa suas verificações. Uma execução bem-sucedida não substitui a validação manual dos fluxos de produto.

## Banco, backup e rollback

O RDS consultado em 09/11/2026 tinha backup automático com retenção de um dia, criptografia, acesso privado e configuração Single-AZ. A proteção contra exclusão não estava habilitada. Confirme os valores atuais antes de uma mudança que possa afetar dados.

Antes de uma alteração destrutiva, capture um snapshot manual com identificador, data, motivo e versão da API. Para uma recuperação, restaure primeiro para uma instância temporária privada e valide schema, migrations e integridade dos dados antes de considerar uma troca controlada de endpoint. Não foi realizado um ensaio de restauração nesta atualização documental.

Para reverter somente uma publicação da API, sem incompatibilidade de schema, publique a imagem ECR imutável anterior. Se houver mudança de schema ou escrita posterior ao snapshot, prepare e revise um plano de recuperação de dados antes de alterar o RDS ativo.

## Observabilidade

O Terraform define seis alarmes CloudWatch para SQS/DLQ, idade da fila, CPU e espaço livre do RDS, rotação de credenciais e falha de entrega do EventBridge. A configuração consultada não apresentava ações SNS nos alarmes; notificações por e-mail não são consideradas comprovadas. A LAJE-40 acompanha a validação ampliada de observabilidade.

## Evidências relacionadas

- **LAJE-149:** consulte a execução e os artefatos associados para evidências de homologação dos fluxos AWS; o status da tarefa sozinho não comprova o runtime atual.
- **LAJE-37:** alinhamento da RFC, Wiki, arquitetura, operação e decisão ao ambiente TCC atual.
- [ADR da arquitetura operacional](../adr/0001-arquitetura-operacional-final.md)
- [Arquitetura da API](../architecture.md)
- [Publicação](../deployment.md)
- [Runbook AWS](../staging-aws.md)
