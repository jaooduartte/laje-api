const implemented = "implemented" as const;
const json = (schema: unknown) => ({ "application/json": { schema } });
const success = (schema: unknown, description = "Operação concluída.") => ({
  description,
  content: json(schema),
});
const error = (description: string) => ({
  description,
  content: json({ $ref: "#/components/schemas/ApiError" }),
});
const bearer = [{ bearerAuth: [] }];
const championshipId = {
  name: "championshipId",
  in: "path",
  required: true,
  schema: { type: "string", format: "uuid" },
};
const matchId = {
  name: "matchId",
  in: "path",
  required: true,
  schema: { type: "string", format: "uuid" },
};
const seasonYearPath = {
  name: "seasonYear",
  in: "path",
  required: true,
  schema: { type: "integer", minimum: 2000, maximum: 2100 },
};
const seasonYearQuery = {
  name: "seasonYear",
  in: "query",
  required: true,
  schema: { type: "integer", minimum: 2000, maximum: 2100 },
};

export const sportsCoreTags = [
  { name: "Brackets", description: "Estrutura e geração das chaves esportivas." },
  { name: "Seasons", description: "Configuração operacional das temporadas de campeonatos." },
];

export const sportsCorePaths = {
  "/api/v1/matches": {
    get: {
      tags: ["Matches"],
      summary: "Lista jogos do núcleo esportivo",
      operationId: "listMatches",
      "x-implementation-status": implemented,
      parameters: [
        { name: "championshipId", in: "query", schema: { type: "string", format: "uuid" } },
        { name: "seasonYear", in: "query", schema: { type: "integer" } },
        {
          name: "status",
          in: "query",
          schema: { type: "array", items: { $ref: "#/components/schemas/MatchStatus" } },
        },
        { name: "sportId", in: "query", schema: { type: "string", format: "uuid" } },
        { name: "teamId", in: "query", schema: { type: "string", format: "uuid" } },
        { name: "naipe", in: "query", schema: { $ref: "#/components/schemas/MatchNaipe" } },
        { name: "division", in: "query", schema: { $ref: "#/components/schemas/TeamDivision" } },
        { $ref: "#/components/parameters/Page" },
        { $ref: "#/components/parameters/PageSize" },
        { $ref: "#/components/parameters/Sort" },
        { $ref: "#/components/parameters/Order" },
      ],
      responses: {
        "200": success({
          type: "object",
          required: ["data", "meta"],
          properties: {
            data: { type: "array", items: { $ref: "#/components/schemas/MatchDto" } },
            meta: { $ref: "#/components/schemas/PaginationMeta" },
          },
        }),
      },
    },
  },
  "/api/v1/matches/{matchId}": {
    get: {
      tags: ["Matches"],
      summary: "Obtém um jogo",
      operationId: "getMatch",
      "x-implementation-status": implemented,
      parameters: [matchId],
      responses: {
        "200": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/MatchDto" } },
        }),
        "404": error("Jogo não encontrado."),
      },
    },
  },
  "/api/v1/matches/{matchId}/start": {
    post: {
      tags: ["Matches"],
      summary: "Inicia um jogo agendado",
      operationId: "startMatch",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [matchId],
      responses: {
        "200": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/MatchDto" } },
        }),
        "401": error("Sessão inválida."),
        "403": error("Permissão control:EDIT necessária."),
        "409": error("Estado do jogo incompatível."),
      },
    },
  },
  "/api/v1/matches/{matchId}/scoreboard": {
    patch: {
      tags: ["Matches"],
      summary: "Atualiza o placar operacional",
      operationId: "updateMatchScoreboard",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [matchId],
      requestBody: {
        required: true,
        content: json({ $ref: "#/components/schemas/ScoreboardUpdateRequest" }),
      },
      responses: {
        "200": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/MatchDto" } },
        }),
        "409": error("Jogo não está ao vivo ou sofreu atualização concorrente."),
        "422": error("Payload inválido."),
      },
    },
  },
  "/api/v1/matches/{matchId}/finish": {
    post: {
      tags: ["Matches"],
      summary: "Encerra um jogo e consolida standings",
      operationId: "finishMatch",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [matchId],
      requestBody: {
        required: false,
        content: json({ $ref: "#/components/schemas/MatchFinishRequest" }),
      },
      responses: {
        "200": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/MatchDto" } },
        }),
        "409": error("Jogo não está ao vivo ou sofreu atualização concorrente."),
      },
    },
  },
  "/api/v1/championships": {
    get: {
      tags: ["Championships"],
      summary: "Lista campeonatos",
      operationId: "listChampionships",
      "x-implementation-status": implemented,
      responses: {
        "200": success({
          type: "object",
          properties: {
            data: { type: "array", items: { $ref: "#/components/schemas/ChampionshipDto" } },
          },
        }),
      },
    },
    post: {
      tags: ["Championships"],
      summary: "Cria campeonato",
      operationId: "createChampionship",
      "x-implementation-status": implemented,
      security: bearer,
      requestBody: {
        required: true,
        content: json({ $ref: "#/components/schemas/ChampionshipWriteRequest" }),
      },
      responses: {
        "201": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/ChampionshipDto" } },
        }),
        "403": error("Permissão settings:EDIT necessária."),
      },
    },
  },
  "/api/v1/championships/{championshipId}": {
    get: {
      tags: ["Championships"],
      summary: "Obtém campeonato",
      operationId: "getChampionship",
      "x-implementation-status": implemented,
      parameters: [championshipId],
      responses: {
        "200": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/ChampionshipDto" } },
        }),
        "404": error("Campeonato não encontrado."),
      },
    },
    patch: {
      tags: ["Championships"],
      summary: "Atualiza campeonato",
      operationId: "updateChampionship",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [championshipId],
      requestBody: {
        required: true,
        content: json({ $ref: "#/components/schemas/ChampionshipWriteRequest" }),
      },
      responses: {
        "200": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/ChampionshipDto" } },
        }),
      },
    },
  },
  "/api/v1/championships/{championshipId}/seasons/{seasonYear}": {
    get: {
      tags: ["Seasons"],
      summary: "Obtém configuração da temporada",
      operationId: "getChampionshipSeason",
      "x-implementation-status": implemented,
      parameters: [championshipId, seasonYearPath],
      responses: {
        "200": success({
          type: "object",
          properties: {
            data: { anyOf: [{ $ref: "#/components/schemas/SeasonSettingsDto" }, { type: "null" }] },
          },
        }),
      },
    },
    put: {
      tags: ["Seasons"],
      summary: "Cria ou atualiza configuração da temporada",
      operationId: "upsertChampionshipSeason",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [championshipId, seasonYearPath],
      requestBody: {
        required: true,
        content: json({ $ref: "#/components/schemas/SeasonSettingsWriteRequest" }),
      },
      responses: {
        "200": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/SeasonSettingsDto" } },
        }),
      },
    },
  },
  "/api/v1/championships/{championshipId}/standings": {
    get: {
      tags: ["Standings"],
      summary: "Obtém classificação oficial ordenada pelo backend",
      operationId: "getChampionshipStandings",
      "x-implementation-status": implemented,
      parameters: [
        championshipId,
        seasonYearQuery,
        { name: "sportId", in: "query", schema: { type: "string", format: "uuid" } },
        { name: "naipe", in: "query", schema: { $ref: "#/components/schemas/MatchNaipe" } },
        { name: "division", in: "query", schema: { $ref: "#/components/schemas/TeamDivision" } },
        { $ref: "#/components/parameters/Page" },
        { $ref: "#/components/parameters/PageSize" },
      ],
      responses: {
        "200": success({
          type: "object",
          properties: {
            data: { type: "array", items: { $ref: "#/components/schemas/StandingDto" } },
            meta: { $ref: "#/components/schemas/PaginationMeta" },
          },
        }),
        "404": error("Campeonato não encontrado."),
      },
    },
  },
  "/api/v1/championships/{championshipId}/calendar": {
    get: {
      tags: ["Championships"],
      summary: "Obtém calendário público do campeonato",
      operationId: "getChampionshipCalendar",
      "x-implementation-status": implemented,
      parameters: [
        championshipId,
        seasonYearQuery,
        { name: "from", in: "query", schema: { type: "string", format: "date" } },
        { name: "to", in: "query", schema: { type: "string", format: "date" } },
        { name: "sportId", in: "query", schema: { type: "string", format: "uuid" } },
        { name: "teamId", in: "query", schema: { type: "string", format: "uuid" } },
        { name: "naipe", in: "query", schema: { $ref: "#/components/schemas/MatchNaipe" } },
        { name: "division", in: "query", schema: { $ref: "#/components/schemas/TeamDivision" } },
      ],
      responses: {
        "200": success({
          type: "object",
          properties: { data: { type: "array", items: { $ref: "#/components/schemas/MatchDto" } } },
        }),
      },
    },
  },
  "/api/v1/championships/{championshipId}/bracket": {
    get: {
      tags: ["Brackets"],
      summary: "Consulta a chave vigente",
      operationId: "getChampionshipBracket",
      "x-implementation-status": implemented,
      parameters: [championshipId, seasonYearQuery],
      responses: {
        "200": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/BracketViewDto" } },
        }),
      },
    },
  },
  "/api/v1/championships/{championshipId}/bracket/generate": {
    post: {
      tags: ["Brackets"],
      summary: "Gera grupos e partidas da fase de grupos",
      operationId: "generateChampionshipBracket",
      "x-implementation-status": implemented,
      security: bearer,
      parameters: [championshipId],
      requestBody: {
        required: true,
        content: json({ $ref: "#/components/schemas/BracketGenerationRequest" }),
      },
      responses: {
        "201": success({
          type: "object",
          properties: { data: { $ref: "#/components/schemas/BracketViewDto" } },
        }),
        "409": error("Já existe chave para a temporada."),
        "422": error("Configuração inválida."),
      },
    },
  },
} as const;

export const sportsCoreSchemas = {
  ChampionshipWriteRequest: {
    type: "object",
    properties: {
      code: { type: "string", enum: ["CLV", "SOCIETY", "INTERLAJE"] },
      name: { type: "string" },
      status: { $ref: "#/components/schemas/ChampionshipStatus" },
      currentSeasonYear: { type: "integer" },
      usesDivisions: { type: "boolean" },
      defaultLocation: { type: ["string", "null"] },
    },
  },
  SeasonSettingsDto: {
    type: "object",
    required: ["id", "championshipId", "seasonYear", "divisionFormat", "divisionSettlementMode"],
    properties: {
      id: { type: "string", format: "uuid" },
      championshipId: { type: "string", format: "uuid" },
      seasonYear: { type: "integer" },
      divisionFormat: { type: "string", enum: ["SEPARATED", "UNIFIED"] },
      divisionSettlementMode: {
        type: "string",
        enum: ["NONE", "PROMOTION_RELEGATION", "TOP_N_TO_PRINCIPAL"],
      },
      principalSlotsCount: { type: ["integer", "null"] },
      principalRelegationCount: { type: ["integer", "null"] },
      accessPromotionCount: { type: ["integer", "null"] },
      yellowCardResetPhase: { type: "string" },
    },
  },
  SeasonSettingsWriteRequest: {
    type: "object",
    properties: {
      divisionFormat: { type: "string", enum: ["SEPARATED", "UNIFIED"] },
      divisionSettlementMode: {
        type: "string",
        enum: ["NONE", "PROMOTION_RELEGATION", "TOP_N_TO_PRINCIPAL"],
      },
      principalSlotsCount: { type: ["integer", "null"] },
      principalRelegationCount: { type: ["integer", "null"] },
      accessPromotionCount: { type: ["integer", "null"] },
      yellowCardResetPhase: { type: "string" },
    },
  },
  BracketGenerationRequest: {
    type: "object",
    required: ["seasonYear", "competitions"],
    properties: {
      seasonYear: { type: "integer" },
      payloadSnapshot: { type: "object", additionalProperties: true },
      competitions: {
        type: "array",
        minItems: 1,
        items: {
          type: "object",
          required: ["sportId", "naipe", "groupsCount", "qualifiersPerGroup", "groups"],
          properties: {
            sportId: { type: "string", format: "uuid" },
            naipe: { $ref: "#/components/schemas/MatchNaipe" },
            division: { anyOf: [{ $ref: "#/components/schemas/TeamDivision" }, { type: "null" }] },
            groupsCount: { type: "integer", minimum: 1 },
            qualifiersPerGroup: { type: "integer", minimum: 1 },
            thirdPlaceMode: { type: "string", enum: ["NONE", "MATCH", "CHAMPION_SEMIFINAL_LOSER"] },
            shouldCompleteKnockoutWithBestSecondPlacedTeams: { type: "boolean" },
            knockoutPairingMode: {
              type: "string",
              enum: ["LINEAR", "RANKING_ALTERNATING", "CLASSIC_SEEDED"],
            },
            groups: {
              type: "array",
              items: {
                type: "object",
                required: ["groupNumber", "teamIds"],
                properties: {
                  groupNumber: { type: "integer", minimum: 1 },
                  teamIds: {
                    type: "array",
                    minItems: 2,
                    items: { type: "string", format: "uuid" },
                  },
                },
              },
            },
          },
        },
      },
    },
  },
  BracketViewDto: {
    type: "object",
    required: ["edition", "competitions"],
    properties: {
      edition: { type: ["object", "null"], additionalProperties: true },
      competitions: { type: "array", items: { type: "object", additionalProperties: true } },
    },
  },
} as const;
