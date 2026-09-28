# Estratégia de migração do LAJE

## Objetivo

Registrar a estratégia de transição entre a arquitetura atual baseada em Supabase e o estado final com frontend na Vercel, `laje-api` na AWS e Amazon RDS for PostgreSQL 17.

A migração é incremental e deve preservar a produção atual até que cada domínio esteja validado em integration/staging e exista uma etapa explícita de cutover e rollback.

## Princípios

1. A produção atual permanece estável durante a migração.
2. Nenhum domínio é migrado apenas por cópia de SQL sem classificar regras, autenticação, jobs e integrações.
3. O frontend não acessa diretamente o RDS no estado final.
4. A mesma base de frontend `laje` seleciona o backend por `VITE_API_URL`.
5. A `laje-api` seleciona o PostgreSQL por `DATABASE_URL`, sem alteração de código por ambiente.
6. Staging e produção usam bancos e credenciais separados.
7. Credenciais e tokens não são versionados; em AWS, secrets ficam em mecanismos apropriados como AWS Secrets Manager.
8. O baseline consolidado não é editado retroativamente. Mudanças futuras de schema são novas migrations.
9. O RDS permanece privado; testes locais não justificam exposição pública do banco.
10. Cutover produtivo exige validação, evidências e rollback definido.

## Estados operacionais

### 1. Produção atual durante a migração

```text
Frontend LAJE na Vercel
        |
        v
Supabase
```

Esse é o ambiente utilizado pelos usuários enquanto a nova arquitetura é construída. Tarefas de staging AWS não devem alterar esse fluxo de forma implícita.

### 2. Integration / staging AWS

```text
Mesmo repositório frontend `laje`
VITE_API_URL=https://<api-staging>
        |
        v
ALB -> ECS/Fargate -> laje-api
        |
        v
Amazon RDS PostgreSQL 17 de staging
```

Esse ambiente é usado para validar contratos HTTP, migrations, importações de ensaio, CORS, TLS, healthchecks, observabilidade e deploy sem afetar a produção atual.

### 3. Produção alvo

```text
Frontend LAJE na Vercel
VITE_API_URL=https://<api-producao>
        |
        v
ALB -> ECS/Fargate -> laje-api
        |
        v
Amazon RDS PostgreSQL 17 de produção
```

A Vercel permanece no frontend por exceção específica aprovada para este projeto. Backend, banco, regras de negócio e serviços operacionais passam para a AWS. Após o cutover, Supabase deixa de exercer o papel de backend e banco principal da solução final.

## Fontes da migração

A migração deve sempre cruzar estes artefatos:

- [Inventário do Supabase](supabase-inventory.md): classifica objetos e dependências atuais;
- [Baseline PostgreSQL](database-baseline.md): ponto zero reproduzível do schema alvo;
- [Arquitetura operacional](../architecture.md): serviços, rede, ambientes e responsabilidades;
- [ADR da arquitetura](../adr/0001-arquitetura-operacional-final.md): decisão formal e trade-offs;
- `infra/database/baseline/schema.sql`: bootstrap estrutural de um PostgreSQL 17 vazio;
- `infra/database/migrations/`: evolução do schema após o baseline.

## Sequência de migração

### Fase 0 — Fundação técnica

Entregas que preparam o repositório e o ambiente sem migrar os fluxos de negócio:

- `LAJE-83`: base inicial do `laje-api`;
- `LAJE-105` a `LAJE-109`: runtime, configuração, banco, quality gate e healthchecks;
- `LAJE-112`: baseline PostgreSQL 17;
- `LAJE-113`: CI inicial;
- `LAJE-127`: ambiente AWS/RDS de integration/staging;
- `LAJE-131`: containerização da API;
- `LAJE-114`: consolidação da documentação de setup e migração.

### Fase 1 — Contratos HTTP

Antes de migrar regras de negócio, os contratos entre frontend e backend devem ser estabilizados:

- `LAJE-115`: OpenAPI e convenções HTTP;
- `LAJE-84`: contratos dos três fluxos prioritários.

A implementação dos domínios deve partir desses contratos para reduzir retrabalho no frontend e na API.

### Fase 2 — Identidade, autorização e auditoria

`LAJE-85` substitui dependências do Supabase Auth, `auth.uid()`, roles e trilhas administrativas por mecanismos controlados pela `laje-api`.

Essa etapa antecede a remoção das policies RLS como mecanismo de autorização da aplicação, pois o RDS não deve ficar exposto ao frontend.

### Fase 3 — Domínios de negócio

A migração funcional ocorre por domínio e deve manter testes e contratos versionados:

- `LAJE-86`: campeonatos, jogos, standings e bracket;
- `LAJE-87`: eventos, links e configurações públicas.

Cada domínio deve classificar funções, triggers e regras atuais entre:

- integridade que permanece no PostgreSQL;
- regra de negócio que migra para Node/Express;
- autorização que migra para a API;
- infraestrutura que será substituída por serviço AWS.

### Fase 4 — Jobs, filas e funções operacionais

`LAJE-126` substitui dependências como `pg_cron`, `pgmq` e Edge Functions por componentes compatíveis com a arquitetura AWS, incluindo SQS/DLQ, EventBridge Scheduler e módulos/workers da API quando aplicável.

Nenhum segredo usado por essas rotinas deve permanecer no banco ou no repositório.

### Fase 5 — Realtime

`LAJE-89` define e implementa a substituição do Supabase Realtime para placar, presença e atualizações públicas.

A solução deve preservar o fluxo controlado pela `laje-api`, sem reintroduzir Supabase como dependência principal do estado final.

### Fase 6 — Migração de dados e cutover

`LAJE-88` concentra o processo de migração dos dados produtivos e deve incluir:

1. snapshot/backup da origem;
2. aplicação do baseline e migrations no RDS de destino;
3. exportação dos dados por ferramenta PostgreSQL adequada;
4. transformação explícita quando houver dependências de Supabase Auth ou objetos não compatíveis;
5. importação no banco de staging e ensaios repetíveis;
6. validação de contagens, chaves, relacionamentos e regras críticas;
7. definição de janela de corte;
8. backup imediatamente anterior ao cutover;
9. execução do cutover;
10. smoke tests pós-corte;
11. rollback documentado e praticável caso a validação falhe.

O baseline e os dados são tratados como artefatos distintos. Nenhum dump produtivo deve ser versionado no GitHub.

### Fase 7 — CI/CD, observabilidade e publicação final

- `LAJE-33`: CI/CD entre frontend Vercel e backend AWS;
- `LAJE-37`: documentação do deploy final;
- `LAJE-40`: observabilidade, dashboards, alertas e evidências operacionais.

O deploy final da API deve ser automatizável, rastreável e não depender de SSH/FTP ou da máquina do autor.

## Estratégia de coexistência

Durante a transição, a aplicação pode possuir módulos já implementados no `laje-api` e outros ainda atendidos pelo ambiente legado. Essa coexistência deve ser explícita por tarefa e por configuração.

Regras:

- não introduzir dual-write entre Supabase e RDS sem tarefa específica, mecanismo de reconciliação e estratégia de rollback;
- não trocar `VITE_API_URL` produtiva antes de o fluxo correspondente estar validado;
- não reutilizar credenciais de produção em staging;
- não usar o RDS de staging como banco produtivo;
- não remover dependências legadas antes da validação funcional equivalente na nova arquitetura;
- registrar dependências transitórias que permanecerem após cada etapa.

## Validação por domínio

Antes de considerar um domínio apto para cutover, validar no mínimo:

- contrato HTTP e tratamento de erros;
- autenticação e autorização quando aplicável;
- integridade das operações no PostgreSQL;
- testes automatizados relevantes;
- comportamento administrativo e público esperado;
- logs suficientes para diagnóstico;
- healthchecks e conectividade do ambiente;
- ausência de credenciais no código, imagem ou documentação;
- caminho de rollback para a alteração realizada.

## Banco de dados e migrations

O baseline versionado em `infra/database/baseline/schema.sql` representa o ponto zero estrutural da arquitetura PostgreSQL alvo.

Após sua consolidação:

- não editar o baseline para representar novas mudanças do produto;
- criar novas migrations em `infra/database/migrations/`;
- preservar ordem e rastreabilidade das migrations;
- validar as migrations em PostgreSQL 17 antes do merge;
- documentar qualquer transformação necessária para dados produtivos na tarefa de migração correspondente.

## Segurança

- RDS não deve aceitar acesso público em `5432`;
- frontend não recebe credenciais de banco;
- `DATABASE_URL`, JWT secrets, tokens de e-mail e integrações ficam fora do repositório;
- workloads AWS devem usar IAM roles e secrets em runtime;
- CORS deve manter allowlist explícita por ambiente;
- comunicação pública deve usar HTTPS;
- conexão da API com o RDS deve utilizar TLS.

## Rastreabilidade

A estratégia deriva das tarefas e artefatos versionados no Jira/GitHub. Mudanças de direção devem ser registradas em tarefa, ADR ou documentação equivalente antes de alterar o estado-alvo.

A produção final somente deve ser considerada migrada quando os fluxos obrigatórios estiverem operando pela nova arquitetura, a persistência principal estiver no PostgreSQL gerenciado e as dependências transitórias do Supabase estiverem removidas ou formalmente justificadas.