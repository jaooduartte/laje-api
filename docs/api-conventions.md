# Convenções HTTP da `laje-api`

## Objetivo

Este documento define a base dos contratos HTTP da `laje-api` antes da migração dos módulos de negócio. As tarefas LAJE-84 e seguintes devem reutilizar estas convenções e registrar explicitamente qualquer exceção necessária.

A especificação executável fica em `src/openapi/openapi.document.ts`. Em desenvolvimento, ela pode ser consultada em `/api-docs` e `/api-docs/openapi.json`.

## Versionamento

A API usa versionamento por URI. A versão atual é:

```text
/api/v1
```

Mudanças compatíveis permanecem em `v1`, por exemplo:

- inclusão de um campo opcional;
- inclusão de um endpoint novo;
- inclusão de um valor novo quando o contrato já define o campo como extensível.

Mudanças incompatíveis exigem nova versão, por exemplo:

- remoção ou renomeação de campo existente;
- alteração de tipo;
- mudança de semântica de um campo obrigatório;
- mudança de rota que quebre consumidores existentes.

A versão não deve ser inferida por header proprietário ou pelo ambiente de deploy.

## Rotas e recursos

- usar substantivos para recursos;
- preferir nomes plurais em recursos de coleção;
- usar `kebab-case` somente quando uma rota realmente precisar de mais de uma palavra;
- evitar verbos no path quando o comportamento puder ser representado pelo método HTTP;
- manter identificadores de recurso no path, por exemplo `/api/v1/championships/{championshipId}`;
- ações de domínio que não se encaixem em CRUD devem ser modeladas explicitamente e documentadas no OpenAPI.

Exemplos:

```text
GET    /api/v1/championships
GET    /api/v1/championships/{championshipId}
POST   /api/v1/championships
PATCH  /api/v1/championships/{championshipId}
DELETE /api/v1/championships/{championshipId}
```

## Conteúdo e representação

- payloads de negócio usam `application/json`;
- datas e horários completos usam ISO 8601, preferencialmente UTC;
- datas sem horário usam `YYYY-MM-DD`;
- identificadores UUID são representados como `string` com `format: uuid` no OpenAPI;
- valores monetários, pontuações e contagens devem declarar unidade e regra de arredondamento quando aplicável;
- campos desconhecidos ou internos não devem ser expostos apenas porque existem no banco.

## Respostas de sucesso

Endpoints de negócio devem usar envelope consistente com `data` e, quando necessário, `meta`.

Recurso único:

```json
{
  "data": {
    "id": "..."
  }
}
```

Coleção paginada:

```json
{
  "data": [],
  "meta": {
    "page": 1,
    "pageSize": 25,
    "totalItems": 0,
    "totalPages": 0
  }
}
```

`204 No Content` não retorna envelope nem corpo.

Os endpoints operacionais `/api/v1`, `/api/v1/health` e `/api/v1/health/database` são exceções deliberadas: mantêm respostas pequenas e estáveis para identificação do serviço e healthchecks.

## Respostas de erro

O formato padrão é:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "One or more fields are invalid.",
    "details": [
      {
        "field": "name",
        "code": "REQUIRED",
        "message": "Name is required."
      }
    ]
  }
}
```

Regras:

- `error.code` é estável e voltado ao consumidor da API;
- `error.message` é seguro para exposição e não deve conter stack trace, SQL, credenciais ou detalhes do driver;
- `error.details` é opcional e usado para erros específicos de campos ou múltiplas violações;
- mensagens destinadas ao usuário final podem ser traduzidas no frontend; o contrato da API não deve depender de texto livre para lógica de negócio;
- erros inesperados usam código genérico e detalhes técnicos ficam somente em logs controlados.

Os middlewares atuais de `404` e `500` já seguem a estrutura `error.code` + `error.message`.

## Status codes

<!-- prettier-ignore -->
| Código | Uso |
| --- | --- |
| `200 OK` | Consulta ou atualização concluída com representação no corpo |
| `201 Created` | Recurso criado; quando possível, retornar `Location` |
| `202 Accepted` | Processamento assíncrono aceito, sem conclusão imediata |
| `204 No Content` | Operação concluída sem corpo de resposta |
| `400 Bad Request` | Requisição malformada ou parâmetro sintaticamente inválido |
| `401 Unauthorized` | Credencial ausente, expirada ou inválida |
| `403 Forbidden` | Usuário autenticado sem permissão para a operação |
| `404 Not Found` | Recurso ou rota inexistente |
| `409 Conflict` | Conflito de estado, unicidade ou concorrência de domínio |
| `422 Unprocessable Content` | Payload válido sintaticamente, mas rejeitado por validação semântica |
| `429 Too Many Requests` | Limite de requisições excedido quando rate limiting for implementado |
| `500 Internal Server Error` | Falha inesperada não atribuível ao consumidor |
| `503 Service Unavailable` | Dependência operacional indisponível ou serviço temporariamente incapaz de atender |

O contrato de cada endpoint deve listar somente os códigos que realmente podem ocorrer naquele fluxo.

## Paginação

Coleções paginadas usam paginação baseada em página:

- `page`: inteiro a partir de `1`, padrão `1`;
- `pageSize`: inteiro de `1` a `100`, padrão `25`.

A resposta usa:

```json
{
  "meta": {
    "page": 1,
    "pageSize": 25,
    "totalItems": 120,
    "totalPages": 5
  }
}
```

Se um fluxo futuro exigir paginação por cursor por razões de consistência ou volume, a exceção deve ser definida no contrato específico; não se deve misturar os dois modelos silenciosamente.

## Filtros, busca e ordenação

- parâmetros de query usam `camelCase`;
- `q` é reservado para busca textual livre quando suportada;
- filtros exatos usam o nome do campo ou conceito de domínio, por exemplo `sportId`, `status` e `teamId`;
- filtros multivalorados repetem a chave, por exemplo `status=scheduled&status=finished`;
- intervalos de data devem usar parâmetros explícitos, como `from` e `to`, com formato documentado;
- `sort` identifica o campo de ordenação aceito pelo endpoint;
- `order` aceita `asc` ou `desc`;
- cada endpoint deve manter allowlist de campos filtráveis e ordenáveis; nomes de colunas internas não constituem automaticamente contrato público.

## Métodos HTTP

- `GET`: leitura sem efeito colateral de domínio;
- `POST`: criação ou comando que não é naturalmente idempotente;
- `PUT`: substituição integral somente quando o recurso realmente suportar essa semântica;
- `PATCH`: atualização parcial;
- `DELETE`: remoção ou cancelamento quando essa for a semântica do recurso.

Requisições `GET`, `PUT` e `DELETE` devem preservar semântica idempotente quando usadas. Comandos assíncronos ou operações sensíveis a repetição devem definir estratégia própria antes da implementação.

## Autenticação futura

A LAJE-115 apenas documenta a integração prevista. A implementação completa pertence à LAJE-85.

O OpenAPI declara o esquema `bearerAuth` com Bearer JWT para servir de base aos contratos futuros:

```text
Authorization: Bearer <token>
```

Convenções previstas:

- `401`: token ausente, inválido ou expirado;
- `403`: identidade válida sem autorização suficiente;
- autorização é aplicada pela `laje-api`, não pelo frontend e não por acesso direto ao RDS;
- tokens, claims e regras de papéis só passam a ser contratuais quando definidos pela LAJE-85;
- a documentação Swagger não deve armazenar credenciais reais.

Nesta etapa, nenhuma rota atual é marcada como protegida no OpenAPI.

## Healthchecks

Os healthchecks mantêm contratos próprios por serem endpoints operacionais:

- `GET /api/v1/health` retorna `200` quando o processo HTTP está saudável e não consulta o banco;
- `GET /api/v1/health/database` retorna `200` quando o PostgreSQL responde e `503` quando está indisponível;
- respostas nunca expõem `DATABASE_URL`, hostname privado, usuário, senha, SQL ou exceção do driver.

Ambos estão declarados no documento OpenAPI.

## Documentação OpenAPI

Em `NODE_ENV=development`:

```text
GET /api-docs
GET /api-docs/openapi.json
```

`/api-docs` fornece a interface Swagger UI e `/api-docs/openapi.json` fornece a especificação OpenAPI 3.1 diretamente.

A interface Swagger UI usa assets de uma versão fixada do `swagger-ui-dist` via CDN apenas como conveniência de desenvolvimento. A especificação JSON é servida pela própria aplicação e continua disponível sem depender da interface.

A documentação não é montada automaticamente em `test` ou `production`. Se futuramente houver necessidade de documentação pública, isso deve ser tratado como decisão explícita, considerando exposição de contratos, autenticação e segurança.

## Segurança e privacidade

- não documentar exemplos com credenciais, tokens ou dados pessoais reais;
- não expor detalhes de infraestrutura privada em respostas de erro;
- validar entradas no limite HTTP antes de executar regras de domínio;
- autenticação e autorização devem ser verificadas antes de operações protegidas;
- o frontend nunca recebe credenciais do PostgreSQL;
- novos contratos devem respeitar minimização de dados e as regras de LGPD aplicáveis ao projeto;
- endpoints administrativos devem documentar autorização, efeitos e trilha de auditoria quando forem implementados.

## Regra para novas rotas

Uma nova rota de negócio só deve ser considerada pronta para merge quando:

1. o path e o método seguem estas convenções ou justificam a exceção;
2. request, response e erros relevantes estão declarados no OpenAPI;
3. status codes possíveis estão documentados;
4. autenticação/autorização estão declaradas quando aplicáveis;
5. filtros, paginação e ordenação estão explícitos quando existirem;
6. testes automatizados validam o contrato relevante;
7. nenhum dado sensível aparece em exemplos, erros ou logs de teste.

Essa regra deve orientar a LAJE-84 e as tarefas de migração dos módulos de negócio.
