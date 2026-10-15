# LAJE-146 — Rate limiting compartilhado (API)

A proteção usa `express-rate-limit` v8 com store PostgreSQL próprio (sujeito à detecção do CodeQL) e utiliza `public.api_rate_limit_windows` no PostgreSQL 17 (Amazon RDS). A contagem é atômica por chave SHA-256 de `scope + IP`, dentro de uma janela fixa, e compartilhada entre todas as réplicas ECS. O banco registra **somente o hash**, sem armazenar IPs originais. O limite é aplicado antes da operação sensível, inclusive a troca de senha e a geração de chaves.

| Endpoint                                                       | Máximo | Janela |
| -------------------------------------------------------------- | -----: | -----: |
| POST /api/v1/auth/login-state                                  |     30 |   60 s |
| POST /api/v1/auth/password-setup                               |      4 |   60 s |
| POST /api/v1/auth/sessions                                     |      8 |   60 s |
| POST /api/v1/auth/sessions/refresh                             |     20 |   60 s |
| PATCH /api/v1/auth/password                                    |      5 |  300 s |
| POST /api/v1/championships/:id/seasons/:year/brackets/generate |      3 |   60 s |

Rejeições retornam HTTP **429**, JSON `RATE_LIMIT_EXCEEDED`, `Retry-After`, `RateLimit-Limit` e `RateLimit-Remaining`. No caso de indisponibilidade do banco, o endpoint sensível falha fechado (500) e não tenta ignorar a proteção. O limite é aplicado via `rateLimit` diretamente nas rotas, com `skip` apenas quando `AUTH_ENABLED=false`. A proteção é acionada quando `AUTH_ENABLED=true`; quando o módulo administrativo está desativado, não acrescenta consultas ao banco.

### Cabeçalhos e ALB

O padrão é **`TRUST_PROXY_HOPS=0`**, que ignora `X-Forwarded-For` e evita spoofing em acesso direto. Na topologia AWS com **um ALB confiável** e tarefas ECS **acessíveis somente a partir do ALB**, definir `TRUST_PROXY_HOPS=1` para que `request.ip` identifique corretamente o cliente. **Não definir valor 1** com tarefas acessíveis pela internet ou proxies adicionais não controlados; nesse caso é preciso redesenhar a confiança por CIDR/proxy.

### Migration e cuidados operacionais

Aplicar `infra/database/migrations/20261015030000_create_api_rate_limit_windows.sql` **antes** de ativar a aplicação com autenticação administrativa. A tabela mantém uma linha por combinação de escopo e IP; adicionar rotina de limpeza de entradas antigas com janela de inatividade >=7 dias de acordo com o volume e uso de índices (não apagar entradas ativas). Não alterar o banco de produção durante revisão da PR. Os testes de middleware usam adaptador determinístico e requisições HTTP locais, sem banco real.

### Limitações e acompanhamento

Janelas fixas permitem rajadas próximas à virada; não substituem AWS WAF, proteção de infraestrutura ou uma política antifraude. Endereços compartilhados por NAT podem consumir o mesmo limite; após homologação, ajustar valores por métricas de 429 e usuários afetados. Referência: [LAJE-146](https://joaoduartte.atlassian.net/browse/LAJE-146).
