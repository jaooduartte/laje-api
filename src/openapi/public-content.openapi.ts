const implemented = "implemented" as const;
const bearer = [{ bearerAuth: [] }];
const apiError = {
  description: "Falha na solicitação.",
  content: {
    "application/json": {
      schema: { $ref: "#/components/schemas/ApiError" },
    },
  },
};
const jsonData = (dataSchema: unknown, description = "Operação concluída.") => ({
  description,
  content: {
    "application/json": {
      schema: {
        type: "object",
        required: ["data"],
        properties: { data: dataSchema },
      },
    },
  },
});
const uuidPath = (name: string) => ({
  name,
  in: "path",
  required: true,
  schema: { type: "string", format: "uuid" },
});
const writeRequest = {
  required: true,
  content: {
    "application/json": {
      schema: { type: "object", additionalProperties: true },
    },
  },
};

export const publicContentTags = [
  {
    name: "League Events",
    description: "Calendário público da liga, reservas e administração de eventos.",
  },
  {
    name: "Public Content",
    description: "Links públicos e configurações de acesso às páginas públicas.",
  },
];

export const publicContentPaths = {
  "/api/v1/league-events": {
    get: {
      tags: ["League Events"],
      summary: "Lista eventos da liga por período",
      operationId: "listLeagueEvents",
      "x-implementation-status": implemented,
      parameters: [
        { name: "from", in: "query", schema: { type: "string", format: "date" } },
        { name: "to", in: "query", schema: { type: "string", format: "date" } },
      ],
      responses: {
        "200": jsonData({ type: "array", items: { type: "object", additionalProperties: true } }),
      },
    },
    post: {
      tags: ["League Events"],
      summary: "Cria um evento da liga",
      operationId: "createLeagueEvent",
      "x-implementation-status": implemented,
      security: bearer,
      requestBody: writeRequest,
      responses: {
        "201": jsonData({ type: "object", additionalProperties: true }),
        "401": apiError,
        "403": apiError,
        "422": apiError,
      },
    },
  },
  "/api/v1/league-events/years": {
    get: {
      tags: ["League Events"],
      summary: "Lista anos disponíveis no calendário da liga",
      operationId: "listLeagueEventYears",
      "x-implementation-status": implemented,
      responses: {
        "200": jsonData({ type: "array", items: { type: "integer" } }),
      },
    },
  },
  "/api/v1/league-events/{eventId}": {
    put: {
      tags: ["League Events"],
      summary: "Atualiza um evento da liga",
      operationId: "updateLeagueEvent",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [uuidPath("eventId")],
      requestBody: writeRequest,
      responses: {
        "200": jsonData({ type: "object", additionalProperties: true }),
        "401": apiError,
        "403": apiError,
        "404": apiError,
        "422": apiError,
      },
    },
    delete: {
      tags: ["League Events"],
      summary: "Exclui um evento da liga",
      operationId: "deleteLeagueEvent",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [uuidPath("eventId")],
      responses: {
        "204": { description: "Evento excluído." },
        "401": apiError,
        "403": apiError,
        "404": apiError,
      },
    },
  },
  "/api/v1/league-events/reservation-requests": {
    get: {
      tags: ["League Events"],
      summary: "Lista solicitações de reserva para administração",
      operationId: "listLeagueEventReservationRequests",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [
        { name: "year", in: "query", required: true, schema: { type: "integer" } },
        { name: "status", in: "query", schema: { type: "string" } },
      ],
      responses: {
        "200": jsonData({ type: "array", items: { type: "object", additionalProperties: true } }),
        "401": apiError,
        "403": apiError,
      },
    },
    post: {
      tags: ["League Events"],
      summary: "Solicita publicamente uma reserva de data",
      operationId: "createLeagueEventReservationRequest",
      "x-implementation-status": implemented,
      requestBody: writeRequest,
      responses: {
        "201": jsonData({ type: "object", additionalProperties: true }),
        "422": apiError,
      },
    },
  },
  "/api/v1/league-events/reservation-requests/conflicts": {
    get: {
      tags: ["League Events"],
      summary: "Lista conflitos públicos de reservas pendentes sem dados pessoais",
      operationId: "listLeagueEventReservationConflicts",
      "x-implementation-status": implemented,
      parameters: [
        {
          name: "date",
          in: "query",
          required: true,
          schema: { type: "string", format: "date" },
        },
      ],
      responses: {
        "200": jsonData({ type: "array", items: { type: "object", additionalProperties: true } }),
        "422": apiError,
      },
    },
  },
  "/api/v1/league-events/reservation-requests/pending-count": {
    get: {
      tags: ["League Events"],
      summary: "Conta solicitações de reserva pendentes",
      operationId: "countPendingLeagueEventReservationRequests",
      "x-implementation-status": implemented,
      security: bearer,
      responses: {
        "200": jsonData({ type: "object", properties: { count: { type: "integer", minimum: 0 } } }),
        "401": apiError,
        "403": apiError,
      },
    },
  },
  "/api/v1/league-events/reservation-requests/{requestId}/review": {
    post: {
      tags: ["League Events"],
      summary: "Aprova ou rejeita uma solicitação de reserva",
      operationId: "reviewLeagueEventReservationRequest",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [uuidPath("requestId")],
      requestBody: writeRequest,
      responses: {
        "200": jsonData({ type: "object", additionalProperties: true }),
        "401": apiError,
        "403": apiError,
        "404": apiError,
        "409": apiError,
        "422": apiError,
      },
    },
  },
  "/api/v1/public/settings": {
    get: {
      tags: ["Public Content"],
      summary: "Obtém configurações públicas de acesso e aviso",
      operationId: "getPublicAccessSettings",
      "x-implementation-status": implemented,
      responses: {
        "200": jsonData({
          anyOf: [{ type: "object", additionalProperties: true }, { type: "null" }],
        }),
      },
    },
    put: {
      tags: ["Public Content"],
      summary: "Atualiza configurações públicas de acesso e aviso",
      operationId: "updatePublicAccessSettings",
      "x-implementation-status": implemented,
      security: bearer,
      requestBody: writeRequest,
      responses: {
        "200": jsonData({ type: "object", additionalProperties: true }),
        "401": apiError,
        "403": apiError,
        "422": apiError,
      },
    },
  },
  "/api/v1/public/links": {
    get: {
      tags: ["Public Content"],
      summary: "Lista seções e links públicos ativos",
      operationId: "listPublicLinks",
      "x-implementation-status": implemented,
      responses: {
        "200": jsonData({ type: "array", items: { type: "object", additionalProperties: true } }),
      },
    },
  },
  "/api/v1/public/links/admin": {
    get: {
      tags: ["Public Content"],
      summary: "Lista seções e links públicos para administração",
      operationId: "listPublicLinksForAdmin",
      "x-implementation-status": implemented,
      security: bearer,
      responses: {
        "200": jsonData({ type: "array", items: { type: "object", additionalProperties: true } }),
        "401": apiError,
        "403": apiError,
      },
    },
  },
  "/api/v1/public/link-sections": {
    post: {
      tags: ["Public Content"],
      summary: "Cria seção de links públicos",
      operationId: "createPublicLinkSection",
      "x-implementation-status": implemented,
      security: bearer,
      requestBody: writeRequest,
      responses: {
        "201": jsonData({ type: "object", additionalProperties: true }),
        "401": apiError,
        "403": apiError,
        "422": apiError,
      },
    },
  },
  "/api/v1/public/link-sections/{sectionId}": {
    put: {
      tags: ["Public Content"],
      summary: "Atualiza seção de links públicos",
      operationId: "updatePublicLinkSection",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [uuidPath("sectionId")],
      requestBody: writeRequest,
      responses: {
        "200": jsonData({ type: "object", additionalProperties: true }),
        "401": apiError,
        "403": apiError,
        "404": apiError,
        "422": apiError,
      },
    },
    delete: {
      tags: ["Public Content"],
      summary: "Exclui seção vazia de links públicos",
      operationId: "deletePublicLinkSection",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [uuidPath("sectionId")],
      responses: {
        "204": { description: "Seção excluída." },
        "401": apiError,
        "403": apiError,
        "404": apiError,
        "409": apiError,
      },
    },
  },
  "/api/v1/public/link-items": {
    post: {
      tags: ["Public Content"],
      summary: "Cria link público",
      operationId: "createPublicLinkItem",
      "x-implementation-status": implemented,
      security: bearer,
      requestBody: writeRequest,
      responses: {
        "201": jsonData({ type: "object", additionalProperties: true }),
        "401": apiError,
        "403": apiError,
        "422": apiError,
      },
    },
  },
  "/api/v1/public/link-items/{itemId}": {
    put: {
      tags: ["Public Content"],
      summary: "Atualiza link público e seus filtros",
      operationId: "updatePublicLinkItem",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [uuidPath("itemId")],
      requestBody: writeRequest,
      responses: {
        "200": jsonData({ type: "object", additionalProperties: true }),
        "401": apiError,
        "403": apiError,
        "404": apiError,
        "422": apiError,
      },
    },
    delete: {
      tags: ["Public Content"],
      summary: "Exclui link público e seus filtros",
      operationId: "deletePublicLinkItem",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [uuidPath("itemId")],
      responses: {
        "204": { description: "Link excluído." },
        "401": apiError,
        "403": apiError,
        "404": apiError,
      },
    },
  },
} as const;
