# LAJE-144 — Auditoria e recuperação da DLQ de bracket preview (AWS staging)

Este procedimento é restrito à conta AWS `549243453554`, região `sa-east-1`, fila `laje-staging-bracket-preview-dlq`. Não se aplica ao ambiente Supabase legado nem a filas produtivas. Acompanhar em [LAJE-144](https://joaoduartte.atlassian.net/browse/LAJE-144).

## Incidente e evidências

- Em 12/10/2026, a rotação da senha do RDS invalidou a credencial PostgreSQL que já estava injetada na task ECS anterior. O worker passou a registrar `PostgresError 28P01` até a atualização controlada do ECS.
- O Scheduler publica `{"type":"MAINTENANCE"}` a cada dois minutos; a fila principal envia à DLQ após cinco recebimentos sem exclusão bem-sucedida.
- Em 12/10/2026, foram identificadas **526 mensagens distintas** na DLQ, todas do tipo `MAINTENANCE`. **Nenhuma** tinha tipo `PROCESS_PREVIEW`, tipo desconhecido ou JSON inválido.
- O intervalo UTC dos eventos auditados foi `2026-10-12T03:09:51Z` a `2026-10-12T20:39:51Z`, coincidente com o incidente de credenciais.
- Após a recuperação, o ECS `laje-staging-api` está com `running=desired=1`, o Scheduler está `ENABLED`, a fila principal está vazia e o worker voltou a registrar `Bracket preview maintenance completed; requeued=0`.
- As mensagens da DLQ **não foram apagadas ou reenviadas** durante a investigação; o alarme `laje-staging-bracket-preview-dlq-not-empty` permaneceu em `ALARM` até o tratamento definitivo.

## Por que não reenviar as mensagens antigas?

`MAINTENANCE` executa `BracketPreviewService.recoverAndCleanup()`, uma rotina periódica que realiza limpeza limitada de prévias em estados finais e não publica mensagens `PROCESS_PREVIEW`. As execuções atuais substituem as execuções perdidas. Reprocessar centenas de mensagens antigas não traz benefício e aumentaria a carga.

Já `PROCESS_PREVIEW` contém um `jobId` específico. Se qualquer mensagem desse tipo aparecer em uma auditoria futura, **não purgue nem faça redrive indiscriminado**. Investigue o estado desse job no PostgreSQL e use a recuperação idempotente prevista no serviço.

## Repetir a auditoria sem alterar mensagens

Pré-requisitos: Node.js 22+, dependências instaladas com `npm ci`, AWS CLI com credenciais **de leitura SQS e mudança de visibilidade** na conta de staging; não são necessárias permissões de exclusão ou de redrive.

```bash
npx tsx scripts/ops/audit-bracket-preview-dlq.ts
```

O utilitário confere a conta AWS, lê o número aproximado de mensagens, recebe cada mensagem apenas para **classificar seu tipo**, deduplica pelo MessageId e devolve a visibilidade de todas as mensagens lidas. Não imprime o corpo, o ReceiptHandle nem informações pessoais. Não faz `DeleteMessage`, `PurgeQueue` nem `StartMessageMoveTask`. Se for interrompido abruptamente, a invisibilidade temporária expira automaticamente em até 300 segundos.

O comando retorna código diferente de zero se houver mensagens não classificáveis, contagem incompleta ou falha em restaurar a visibilidade. O número de mensagens da API é aproximado; confira a contagem antes e depois e repita a auditoria se a fila estiver recebendo eventos ou outro operador a estiver lendo.

## Tratamento controlado (exige aprovação explícita)

1. Preservar a evidência da classificação integral no Jira, com quantidade, tipos e intervalo UTC. Confirmar DLQ estável e fila principal sendo consumida.
2. Se houver **qualquer** `PROCESS_PREVIEW` ou payload inválido, interromper a limpeza, verificar estado do job e decidir recuperação individual com idempotência comprovada.
3. Quando comprovado que a DLQ contém somente `MAINTENANCE` obsoletas, obter aprovação explícita do responsável pela LAJE antes de qualquer operação destrutiva.
4. Um operador autorizado pode **limpar exclusivamente essa DLQ de staging** pelo console AWS após uma última verificação de tipo/quantidade e identidade da conta. Não limpar a fila principal. A operação de purge é irreversível.
5. Verificar que a DLQ chega a zero, não há mensagens `in-flight`, a fila principal continua sem acúmulo e o alarme CloudWatch retorna ao estado `OK` após a janela de avaliação.
6. Registrar horário, contagens antes/depois, decisão, identidade do executor e métricas no Jira. Não tratar apenas o estado do alarme como prova de saúde do worker.

## Prevenção

A correção definitiva da causa está na [LAJE-143](https://joaoduartte.atlassian.net/browse/LAJE-143): reagir à rotação concluída da senha RDS e atualizar as tasks do ECS automaticamente. Qualquer proposta de mudar retries, política de redrive ou periodicidade precisa de avaliação própria, testes e revisão por pares.

**Atenção:** este procedimento não autoriza alteração de Terraform state, segredo RDS, banco de dados, plataforma Vercel ou ambiente Supabase.
