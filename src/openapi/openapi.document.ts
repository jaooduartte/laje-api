import { authPaths, authSchemas } from "./auth.openapi.js";
import {
  priorityFlowPaths,
  priorityFlowSchemas,
  priorityFlowSecuritySchemes,
  priorityFlowTags,
} from "./priority-flows.openapi.js";
import { publicContentPaths, publicContentTags } from "./public-content.openapi.js";
import {
  sportsCoreContractPaths,
  sportsCoreContractSchemas,
} from "./sports-core-contracts.openapi.js";
import { sportsCorePaths, sportsCoreSchemas, sportsCoreTags } from "./sports-core.openapi.js";

export const openApiDocument = {
  openapi: "3.1.0",
  info: {
    title: "LAJE API",
    version: "1.0.0",
    description:
      "Contratos HTTP da API dedicada da Liga das Atléticas de Joinville. As convenções formais estão registradas em docs/api-conventions.md. Endpoints com x-implementation-status=planned estão definidos contratualmente, mas ainda não implementados; os marcados como implemented possuem rota ativa no laje-api.",
  },
  servers: [
    {
      url: "http://localhost:3000",
      description: "Ambiente local de desenvolvimento",
    },
  ],
  tags: [
    {
      name: "Service",
      description: "Metadados mínimos do serviço e da versão HTTP ativa.",
    },
    {
      name: "Health",
      description: "Endpoints operacionais para aplicação e dependência PostgreSQL.",
    },
    ...priorityFlowTags,
    ...sportsCoreTags,
    ...publicContentTags,
  ],
  paths: {
    "/api/v1": {
      get: {
        tags: ["Service"],
        summary: "Identifica o serviço e a versão da API",
        operationId: "getServiceMetadata",
        responses: {
          "200": {
            description: "Serviço disponível.",
            content: {
              "application/json": {
                schema: {
                  $ref: "#/components/schemas/ServiceMetadata",
                },
              },
            },
          },
        },
      },
    },
    "/api/v1/health": {
      get: {
        tags: ["Health"],
        summary: "Verifica a saúde do processo HTTP",
        description:
          "Liveness da aplicação. Este endpoint não consulta o PostgreSQL e mantém resposta mínima para uso operacional.",
        operationId: "getApplicationHealth",
        responses: {
          "200": {
            description: "Aplicação saudável.",
            content: {
              "application/json": {
                schema: {
                  $ref: "#/components/schemas/ApplicationHealth",
                },
              },
            },
          },
        },
      },
    },
    "/api/v1/health/database": {
      get: {
        tags: ["Health"],
        summary: "Verifica a conectividade com o PostgreSQL",
        description:
          "Executa uma verificação leve de conectividade. A resposta nunca inclui credenciais, hostname interno, SQL ou detalhes da exceção do driver.",
        operationId: "getDatabaseHealth",
        responses: {
          "200": {
            description: "PostgreSQL acessível.",
            content: {
              "application/json": {
                schema: {
                  $ref: "#/components/schemas/DatabaseHealth",
                },
              },
            },
          },
          "503": {
            description: "PostgreSQL temporariamente indisponível.",
            content: {
              "application/json": {
                schema: {
                  $ref: "#/components/schemas/DatabaseUnavailableHealth",
                },
              },
            },
          },
        },
      },
    },
    ...priorityFlowPaths,
    ...authPaths,
    ...sportsCorePaths,
    ...sportsCoreContractPaths,
    ...publicContentPaths,
  },
  components: {
    securitySchemes: {
      bearerAuth: {
        type: "http",
        scheme: "bearer",
        bearerFormat: "JWT",
        description:
          "Bearer JWT de curta duração emitido pela laje-api para sessões administrativas da arquitetura dedicada.",
      },
      ...priorityFlowSecuritySchemes,
    },
    parameters: {
      Page: {
        name: "page",
        in: "query",
        description: "Página solicitada em coleções paginadas.",
        schema: { type: "integer", minimum: 1, default: 1 },
      },
      PageSize: {
        name: "pageSize",
        in: "query",
        description: "Quantidade de itens por página.",
        schema: { type: "integer", minimum: 1, maximum: 100, default: 50 },
      },
      Search: {
        name: "q",
        in: "query",
        description: "Busca textual quando suportada pelo recurso.",
        schema: { type: "string", minLength: 1 },
      },
      Sort: {
        name: "sort",
        in: "query",
        description: "Campo de ordenação permitido pelo endpoint.",
        schema: { type: "string" },
      },
      Order: {
        name: "order",
        in: "query",
        description: "Direção da ordenação.",
        schema: { type: "string", enum: ["asc", "desc"], default: "asc" },
      },
    },
    schemas: {
      ServiceMetadata: {
        type: "object",
        required: ["service", "version", "status"],
        additionalProperties: false,
        properties: {
          service: { type: "string", const: "laje-api" },
          version: { type: "string", const: "v1" },
          status: { type: "string", const: "ready" },
        },
      },
      ApplicationHealth: {
        type: "object",
        required: ["service", "status"],
        additionalProperties: false,
        properties: {
          service: { type: "string", const: "laje-api" },
          status: { type: "string", const: "ok" },
        },
      },
      DatabaseHealth: {
        type: "object",
        required: ["database", "status"],
        additionalProperties: false,
        properties: {
          database: { type: "string", const: "reachable" },
          status: { type: "string", const: "ok" },
        },
      },
      DatabaseUnavailableHealth: {
        type: "object",
        required: ["database", "status"],
        additionalProperties: false,
        properties: {
          database: { type: "string", const: "unreachable" },
          status: { type: "string", const: "unavailable" },
        },
      },
      ApiSuccess: {
        type: "object",
        required: ["data"],
        additionalProperties: false,
        properties: {
          data: { description: "Representação principal retornada pelo endpoint de negócio." },
          meta: {
            type: "object",
            description: "Metadados opcionais, como paginação.",
            additionalProperties: true,
          },
        },
      },
      PaginationMeta: {
        type: "object",
        required: ["page", "pageSize", "total", "totalPages"],
        additionalProperties: false,
        properties: {
          page: { type: "integer", minimum: 1 },
          pageSize: { type: "integer", minimum: 1, maximum: 100 },
          total: { type: "integer", minimum: 0 },
          totalPages: { type: "integer", minimum: 0 },
          ordering: { type: "string" },
        },
      },
      ApiErrorDetail: {
        type: "object",
        required: ["code", "message"],
        additionalProperties: false,
        properties: {
          field: { type: "string", description: "Campo relacionado ao erro quando aplicável." },
          code: { type: "string", description: "Código estável e legível por máquina." },
          message: {
            type: "string",
            description: "Mensagem segura para diagnóstico pelo consumidor.",
          },
        },
      },
      ApiError: {
        type: "object",
        required: ["error"],
        additionalProperties: false,
        properties: {
          error: {
            type: "object",
            required: ["code", "message"],
            additionalProperties: false,
            properties: {
              code: { type: "string", example: "ROUTE_NOT_FOUND" },
              message: { type: "string", example: "The requested resource was not found." },
              details: { type: "array", items: { $ref: "#/components/schemas/ApiErrorDetail" } },
            },
          },
        },
      },
      ...priorityFlowSchemas,
      ...authSchemas,
      ...sportsCoreSchemas,
      ...sportsCoreContractSchemas,
    },
  },
} as const;
