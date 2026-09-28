const planned = "planned" as const;

const json = (schema: object) => ({
  "application/json": { schema },
});

const success = (schemaRef: string) => ({
  description: "Operação concluída.",
  content: json({
    type: "object",
    required: ["data"],
    additionalProperties: false,
    properties: { data: { $ref: schemaRef } },
  }),
});

const paginated = (schemaRef: string) => ({
  description: "Coleção paginada.",
  content: json({
    type: "object",
    required: ["data", "meta"],
    additionalProperties: false,
    properties: {
      data: { type: "array", items: { $ref: schemaRef } },
      meta: { $ref: "#/components/schemas/PaginationMeta" },
    },
  }),
});

const error = (description: string) => ({
  description,
  content: json({ $ref: "#/components/schemas/ApiError" }),
});

const idParameter = (name: string, description: string) => ({
  name,
  in: "path",
  required: true,
  description,
  schema: { type: "string", format: "uuid" },
});

const queryParameter = (name: string, description: string, schema: object, required = false) => ({
  name,
  in: "query",
  required,
  description,
  schema,
});

export const priorityFlowTags = [
  {
    name: "Authentication",
    description: "Contrato planejado de autenticação e contexto administrativo.",
  },
  {
    name: "Matches",
    description: "Contrato planejado de consulta e operação ao vivo de jogos.",
  },
  {
    name: "Championships",
    description: "Contrato planejado de consultas públicas de campeonatos.",
  },
] as const;

export const priorityFlowSecuritySchemes = {
  refreshCookie: {
    type: "apiKey",
    in: "cookie",
    name: "laje_refresh_token",
    description:
      "Cookie de renovação planejado para LAJE-85. Em produção deve ser HttpOnly e Secure; o token não é retornado no corpo.",
  },
} as const;

export const priorityFlowPaths = {
  "/api/v1/auth/sessions": {
    post: {
      tags: ["Authentication"],
      summary: "Cria uma sessão administrativa",
      operationId: "createAdminSession",
      "x-implementation-status": planned,
      requestBody: {
        required: true,
        content: json({ $ref: "#/components/schemas/AuthLoginRequest" }),
      },
      responses: {
        "200": success("#/components/schemas/AuthSession"),
        "401": error("Credenciais inválidas."),
        "403": error("Identidade sem acesso ao painel administrativo."),
        "422": error("Payload semanticamente inválido."),
      },
    },
  },
  "/api/v1/auth/sessions/refresh": {
    post: {
      tags: ["Authentication"],
      summary: "Renova a sessão administrativa",
      operationId: "refreshAdminSession",
      "x-implementation-status": planned,
      security: [{ refreshCookie: [] }],
      responses: {
        "200": success("#/components/schemas/AuthSession"),
        "401": error("Sessão de renovação ausente, inválida ou expirada."),
      },
    },
  },
  "/api/v1/auth/sessions/current": {
    delete: {
      tags: ["Authentication"],
      summary: "Encerra a sessão administrativa atual",
      operationId: "deleteCurrentAdminSession",
      "x-implementation-status": planned,
      security: [{ bearerAuth: [] }],
      responses: {
        "204": { description: "Sessão encerrada; resposta sem corpo." },
        "401": error("Sessão ausente, inválida ou expirada."),
      },
    },
  },
  "/api/v1/auth/me": {
    get: {
      tags: ["Authentication"],
      summary: "Obtém identidade e permissões administrativas atuais",
      operationId: "getCurrentAdminContext",
      "x-implementation-status": planned,
      security: [{ bearerAuth: [] }],
      responses: {
        "200": success("#/components/schemas/AdminContext"),
        "401": error("Sessão ausente, inválida ou expirada."),
        "403": error("Identidade sem acesso ao painel administrativo."),
      },
    },
  },
  "/api/v1/matches": {
    get: {
      tags: ["Matches"],
      summary: "Lista jogos com filtros e paginação",
      operationId: "listMatches",
      "x-implementation-status": planned,
      parameters: [
        queryParameter("championshipId", "Campeonato.", { type: "string", format: "uuid" }),
        queryParameter("seasonYear", "Temporada.", { type: "integer", minimum: 2000 }),
        {
          name: "status",
          in: "query",
          description: "Status repetível.",
          style: "form",
          explode: true,
          schema: {
            type: "array",
            items: { $ref: "#/components/schemas/MatchStatus" },
          },
        },
        queryParameter("sportId", "Modalidade.", { type: "string", format: "uuid" }),
        queryParameter("teamId", "Equipe mandante ou visitante.", {
          type: "string",
          format: "uuid",
        }),
        queryParameter("naipe", "Naipe.", { $ref: "#/components/schemas/MatchNaipe" }),
        queryParameter("division", "Divisão.", { $ref: "#/components/schemas/TeamDivision" }),
        queryParameter("location", "Local.", { type: "string" }),
        queryParameter("courtName", "Quadra/campo.", { type: "string" }),
        { $ref: "#/components/parameters/Page" },
        { $ref: "#/components/parameters/PageSize" },
        { $ref: "#/components/parameters/Sort" },
        { $ref: "#/components/parameters/Order" },
      ],
      responses: {
        "200": paginated("#/components/schemas/MatchDto"),
        "422": error("Filtros semanticamente inválidos."),
      },
    },
  },
  "/api/v1/matches/{matchId}": {
    get: {
      tags: ["Matches"],
      summary: "Consulta um jogo",
      operationId: "getMatch",
      "x-implementation-status": planned,
      parameters: [idParameter("matchId", "Identificador do jogo.")],
      responses: {
        "200": success("#/components/schemas/MatchDto"),
        "404": error("Jogo não encontrado."),
      },
    },
  },
  "/api/v1/matches/{matchId}/start": {
    post: {
      tags: ["Matches"],
      summary: "Inicia um jogo agendado",
      description: "Requer permissão efetiva control:EDIT.",
      operationId: "startMatch",
      "x-implementation-status": planned,
      security: [{ bearerAuth: [] }],
      parameters: [idParameter("matchId", "Identificador do jogo.")],
      responses: {
        "200": success("#/components/schemas/MatchDto"),
        "401": error("Sessão ausente ou inválida."),
        "403": error("Permissão insuficiente."),
        "404": error("Jogo não encontrado."),
        "409": error("Estado atual incompatível com início."),
      },
    },
  },
  "/api/v1/matches/{matchId}/scoreboard": {
    patch: {
      tags: ["Matches"],
      summary: "Atualiza o placar operacional do jogo",
      description: "Requer permissão efetiva control:EDIT.",
      operationId: "updateMatchScoreboard",
      "x-implementation-status": planned,
      security: [{ bearerAuth: [] }],
      parameters: [idParameter("matchId", "Identificador do jogo.")],
      requestBody: {
        required: true,
        content: json({ $ref: "#/components/schemas/ScoreboardUpdateRequest" }),
      },
      responses: {
        "200": success("#/components/schemas/MatchDto"),
        "401": error("Sessão ausente ou inválida."),
        "403": error("Permissão insuficiente."),
        "404": error("Jogo não encontrado."),
        "409": error("Conflito de estado ou atualização concorrente."),
        "422": error("Placar incompatível com as regras do jogo."),
      },
    },
  },
  "/api/v1/matches/{matchId}/finish": {
    post: {
      tags: ["Matches"],
      summary: "Encerra um jogo ao vivo",
      description: "Requer permissão efetiva control:EDIT.",
      operationId: "finishMatch",
      "x-implementation-status": planned,
      security: [{ bearerAuth: [] }],
      parameters: [idParameter("matchId", "Identificador do jogo.")],
      requestBody: {
        required: false,
        content: json({ $ref: "#/components/schemas/MatchFinishRequest" }),
      },
      responses: {
        "200": success("#/components/schemas/MatchDto"),
        "401": error("Sessão ausente ou inválida."),
        "403": error("Permissão insuficiente."),
        "404": error("Jogo não encontrado."),
        "409": error("Estado atual incompatível com encerramento."),
        "422": error("Resultado incompatível com as regras do jogo."),
      },
    },
  },
  "/api/v1/championships": {
    get: {
      tags: ["Championships"],
      summary: "Lista campeonatos públicos",
      operationId: "listChampionships",
      "x-implementation-status": planned,
      parameters: [
        queryParameter("status", "Status do campeonato.", {
          $ref: "#/components/schemas/ChampionshipStatus",
        }),
      ],
      responses: {
        "200": {
          description: "Campeonatos públicos.",
          content: json({
            type: "object",
            required: ["data"],
            additionalProperties: false,
            properties: {
              data: {
                type: "array",
                items: { $ref: "#/components/schemas/ChampionshipDto" },
              },
            },
          }),
        },
      },
    },
  },
  "/api/v1/championships/{championshipId}": {
    get: {
      tags: ["Championships"],
      summary: "Consulta um campeonato público",
      operationId: "getChampionship",
      "x-implementation-status": planned,
      parameters: [idParameter("championshipId", "Identificador do campeonato.")],
      responses: {
        "200": success("#/components/schemas/ChampionshipDto"),
        "404": error("Campeonato não encontrado."),
      },
    },
  },
  "/api/v1/championships/{championshipId}/standings": {
    get: {
      tags: ["Championships"],
      summary: "Consulta classificação oficial do campeonato",
      description: "A API devolve a ordem oficial já resolvida, incluindo desempates aplicáveis.",
      operationId: "getChampionshipStandings",
      "x-implementation-status": planned,
      parameters: [
        idParameter("championshipId", "Identificador do campeonato."),
        queryParameter("seasonYear", "Temporada.", { type: "integer", minimum: 2000 }, true),
        queryParameter("sportId", "Modalidade.", { type: "string", format: "uuid" }),
        queryParameter("naipe", "Naipe.", { $ref: "#/components/schemas/MatchNaipe" }),
        queryParameter("division", "Divisão.", { $ref: "#/components/schemas/TeamDivision" }),
        { $ref: "#/components/parameters/Page" },
        { $ref: "#/components/parameters/PageSize" },
      ],
      responses: {
        "200": paginated("#/components/schemas/StandingDto"),
        "404": error("Campeonato não encontrado."),
        "422": error("Filtros semanticamente inválidos."),
      },
    },
  },
  "/api/v1/championships/{championshipId}/calendar": {
    get: {
      tags: ["Championships"],
      summary: "Consulta agenda pública de jogos do campeonato",
      operationId: "getChampionshipCalendar",
      "x-implementation-status": planned,
      parameters: [
        idParameter("championshipId", "Identificador do campeonato."),
        queryParameter("seasonYear", "Temporada.", { type: "integer", minimum: 2000 }, true),
        queryParameter("from", "Data inicial inclusiva.", { type: "string", format: "date" }),
        queryParameter("to", "Data final inclusiva.", { type: "string", format: "date" }),
        queryParameter("sportId", "Modalidade.", { type: "string", format: "uuid" }),
        queryParameter("teamId", "Equipe.", { type: "string", format: "uuid" }),
        queryParameter("naipe", "Naipe.", { $ref: "#/components/schemas/MatchNaipe" }),
        queryParameter("division", "Divisão.", { $ref: "#/components/schemas/TeamDivision" }),
        { $ref: "#/components/parameters/Page" },
        { $ref: "#/components/parameters/PageSize" },
      ],
      responses: {
        "200": paginated("#/components/schemas/MatchDto"),
        "404": error("Campeonato não encontrado."),
        "422": error("Filtros semanticamente inválidos."),
      },
    },
  },
} as const;

export const priorityFlowSchemas = {
  AuthLoginRequest: {
    type: "object",
    required: ["email", "password"],
    additionalProperties: false,
    properties: {
      email: { type: "string", format: "email" },
      password: { type: "string", minLength: 1, writeOnly: true },
    },
  },
  AdminPermission: {
    type: "object",
    required: ["scope", "level"],
    additionalProperties: false,
    properties: {
      scope: {
        type: "string",
        enum: [
          "bracket_setup",
          "matches",
          "control",
          "individual_events",
          "teams",
          "sports",
          "events",
          "links",
          "logs",
          "users",
          "account",
          "standings",
          "championship_status",
          "settings",
          "score_sheet_review",
          "tie_breaks",
          "championship_schedule",
          "opening_ceremony_bonus",
        ],
      },
      level: { type: "string", enum: ["NONE", "VIEW", "EDIT"] },
    },
  },
  AdminProfile: {
    type: "object",
    required: ["id", "name"],
    additionalProperties: false,
    properties: {
      id: { type: "string", format: "uuid" },
      name: { type: "string" },
    },
  },
  AdminContext: {
    type: "object",
    required: ["id", "email", "role", "profile", "permissions", "canAccessAdminPanel"],
    additionalProperties: false,
    properties: {
      id: { type: "string", format: "uuid" },
      email: { type: "string", format: "email" },
      role: {
        type: ["string", "null"],
        enum: ["admin", "eventos", "mesa", null],
      },
      profile: {
        oneOf: [{ $ref: "#/components/schemas/AdminProfile" }, { type: "null" }],
      },
      permissions: {
        type: "array",
        items: { $ref: "#/components/schemas/AdminPermission" },
      },
      canAccessAdminPanel: { type: "boolean" },
    },
  },
  AuthSession: {
    type: "object",
    required: ["accessToken", "tokenType", "expiresAt", "user"],
    additionalProperties: false,
    properties: {
      accessToken: { type: "string", description: "JWT de curta duração." },
      tokenType: { type: "string", const: "Bearer" },
      expiresAt: { type: "string", format: "date-time" },
      user: { $ref: "#/components/schemas/AdminContext" },
    },
  },
  MatchStatus: {
    type: "string",
    enum: ["SCHEDULED", "LIVE", "FINISHED"],
  },
  MatchNaipe: {
    type: "string",
    enum: ["MASCULINO", "FEMININO", "MISTO"],
  },
  TeamDivision: {
    type: ["string", "null"],
    enum: ["DIVISAO_PRINCIPAL", "DIVISAO_ACESSO", null],
  },
  ChampionshipStatus: {
    type: "string",
    enum: ["PLANNING", "UPCOMING", "REVIEW", "IN_PROGRESS", "FINISHED"],
  },
  TeamSummary: {
    type: "object",
    required: ["id", "name"],
    additionalProperties: false,
    properties: {
      id: { type: "string", format: "uuid" },
      name: { type: "string" },
    },
  },
  SportSummary: {
    type: "object",
    required: ["id", "name"],
    additionalProperties: false,
    properties: {
      id: { type: "string", format: "uuid" },
      name: { type: "string" },
      code: { type: ["string", "null"] },
    },
  },
  MatchDto: {
    type: "object",
    required: [
      "id",
      "championshipId",
      "seasonYear",
      "sport",
      "homeTeam",
      "awayTeam",
      "status",
      "naipe",
      "division",
      "homeScore",
      "awayScore",
    ],
    additionalProperties: false,
    properties: {
      id: { type: "string", format: "uuid" },
      championshipId: { type: "string", format: "uuid" },
      seasonYear: { type: "integer" },
      sport: { $ref: "#/components/schemas/SportSummary" },
      homeTeam: { $ref: "#/components/schemas/TeamSummary" },
      awayTeam: { $ref: "#/components/schemas/TeamSummary" },
      status: { $ref: "#/components/schemas/MatchStatus" },
      naipe: { $ref: "#/components/schemas/MatchNaipe" },
      division: { $ref: "#/components/schemas/TeamDivision" },
      groupNumber: { type: ["integer", "null"] },
      location: { type: ["string", "null"] },
      courtName: { type: ["string", "null"] },
      scheduledDate: { type: ["string", "null"], format: "date" },
      scheduledStartTime: { type: ["string", "null"] },
      startTime: { type: ["string", "null"], format: "date-time" },
      endTime: { type: ["string", "null"], format: "date-time" },
      supportsCards: { type: "boolean" },
      resultRule: { type: ["string", "null"], enum: ["POINTS", "SETS", null] },
      homeScore: { type: "integer", minimum: 0 },
      awayScore: { type: "integer", minimum: 0 },
      currentSetHomeScore: { type: ["integer", "null"], minimum: 0 },
      currentSetAwayScore: { type: ["integer", "null"], minimum: 0 },
      homePenaltyScore: { type: ["integer", "null"], minimum: 0 },
      awayPenaltyScore: { type: ["integer", "null"], minimum: 0 },
      homeYellowCards: { type: "integer", minimum: 0 },
      awayYellowCards: { type: "integer", minimum: 0 },
      homeRedCards: { type: "integer", minimum: 0 },
      awayRedCards: { type: "integer", minimum: 0 },
      homeBlueCards: { type: "integer", minimum: 0 },
      awayBlueCards: { type: "integer", minimum: 0 },
      homeTwoMinutePenalties: { type: "integer", minimum: 0 },
      awayTwoMinutePenalties: { type: "integer", minimum: 0 },
      isWalkover: { type: "boolean" },
      isDoubleWalkover: { type: "boolean" },
      createdAt: { type: "string", format: "date-time" },
    },
  },
  ScoreboardUpdateRequest: {
    type: "object",
    minProperties: 1,
    additionalProperties: false,
    properties: {
      homeScore: { type: "integer", minimum: 0 },
      awayScore: { type: "integer", minimum: 0 },
      currentSetHomeScore: { type: ["integer", "null"], minimum: 0 },
      currentSetAwayScore: { type: ["integer", "null"], minimum: 0 },
      homePenaltyScore: { type: ["integer", "null"], minimum: 0 },
      awayPenaltyScore: { type: ["integer", "null"], minimum: 0 },
      homeYellowCards: { type: "integer", minimum: 0 },
      awayYellowCards: { type: "integer", minimum: 0 },
      homeRedCards: { type: "integer", minimum: 0 },
      awayRedCards: { type: "integer", minimum: 0 },
      homeBlueCards: { type: "integer", minimum: 0 },
      awayBlueCards: { type: "integer", minimum: 0 },
      homeTwoMinutePenalties: { type: "integer", minimum: 0 },
      awayTwoMinutePenalties: { type: "integer", minimum: 0 },
    },
  },
  MatchFinishRequest: {
    type: "object",
    additionalProperties: false,
    properties: {
      homeScore: { type: "integer", minimum: 0 },
      awayScore: { type: "integer", minimum: 0 },
      homePenaltyScore: { type: ["integer", "null"], minimum: 0 },
      awayPenaltyScore: { type: ["integer", "null"], minimum: 0 },
      isWalkover: { type: "boolean" },
      isDoubleWalkover: { type: "boolean" },
      walkoverLoserTeamId: { type: ["string", "null"], format: "uuid" },
    },
  },
  ChampionshipDto: {
    type: "object",
    required: ["id", "code", "name", "status", "currentSeasonYear", "usesDivisions"],
    additionalProperties: false,
    properties: {
      id: { type: "string", format: "uuid" },
      code: { type: "string", enum: ["CLV", "SOCIETY", "INTERLAJE"] },
      name: { type: "string" },
      status: { $ref: "#/components/schemas/ChampionshipStatus" },
      currentSeasonYear: { type: "integer" },
      usesDivisions: { type: "boolean" },
      defaultLocation: { type: ["string", "null"] },
    },
  },
  StandingDto: {
    type: "object",
    required: [
      "position",
      "championshipId",
      "seasonYear",
      "sport",
      "team",
      "naipe",
      "division",
      "played",
      "wins",
      "draws",
      "losses",
      "points",
    ],
    additionalProperties: false,
    properties: {
      position: { type: "integer", minimum: 1 },
      championshipId: { type: "string", format: "uuid" },
      seasonYear: { type: "integer" },
      sport: { $ref: "#/components/schemas/SportSummary" },
      team: { $ref: "#/components/schemas/TeamSummary" },
      naipe: { $ref: "#/components/schemas/MatchNaipe" },
      division: { $ref: "#/components/schemas/TeamDivision" },
      played: { type: "integer", minimum: 0 },
      wins: { type: "integer", minimum: 0 },
      draws: { type: "integer", minimum: 0 },
      losses: { type: "integer", minimum: 0 },
      goalsFor: { type: "integer" },
      goalsAgainst: { type: "integer" },
      goalDifference: { type: "integer" },
      points: { type: "number" },
      yellowCards: { type: "integer", minimum: 0 },
      redCards: { type: "integer", minimum: 0 },
      blueCards: { type: "integer", minimum: 0 },
      twoMinutePenalties: { type: "integer", minimum: 0 },
      setsFor: { type: "integer", minimum: 0 },
      setsAgainst: { type: "integer", minimum: 0 },
      rallyPointsFor: { type: "integer", minimum: 0 },
      rallyPointsAgainst: { type: "integer", minimum: 0 },
      isIndividualSport: { type: "boolean" },
      scoredEventsCount: { type: "integer", minimum: 0 },
      firstPlaces: { type: "integer", minimum: 0 },
      secondPlaces: { type: "integer", minimum: 0 },
      thirdPlaces: { type: "integer", minimum: 0 },
    },
  },
} as const;
