const errorResponses = {
  "401": {
    description: "Credencial ou sessão inválida.",
    content: { "application/json": { schema: { $ref: "#/components/schemas/ApiError" } } },
  },
  "403": {
    description: "Identidade sem acesso administrativo suficiente.",
    content: { "application/json": { schema: { $ref: "#/components/schemas/ApiError" } } },
  },
  "422": {
    description: "Payload inválido.",
    content: { "application/json": { schema: { $ref: "#/components/schemas/ApiError" } } },
  },
} as const;

const sessionResponse = {
  "200": {
    description: "Sessão administrativa válida.",
    content: {
      "application/json": {
        schema: {
          type: "object",
          required: ["data"],
          properties: { data: { $ref: "#/components/schemas/AuthSession" } },
        },
      },
    },
  },
  ...errorResponses,
} as const;

export const authPaths = {
  "/api/v1/auth/login-state": {
    post: {
      tags: ["Authentication"],
      summary: "Resolve o estado de primeiro acesso de um login administrativo",
      operationId: "resolveAdminLoginState",
      requestBody: {
        required: true,
        content: {
          "application/json": { schema: { $ref: "#/components/schemas/LoginStateRequest" } },
        },
      },
      responses: {
        "200": {
          description: "Estado administrativo localizado.",
          content: {
            "application/json": {
              schema: {
                type: "object",
                required: ["data"],
                properties: { data: { $ref: "#/components/schemas/LoginState" } },
              },
            },
          },
        },
        "404": {
          description: "Login administrativo inexistente.",
          content: { "application/json": { schema: { $ref: "#/components/schemas/ApiError" } } },
        },
        "422": errorResponses["422"],
      },
    },
  },
  "/api/v1/auth/password-setup": {
    post: {
      tags: ["Authentication"],
      summary: "Conclui o primeiro acesso e cria a sessão administrativa",
      operationId: "setupAdminPassword",
      requestBody: {
        required: true,
        content: {
          "application/json": { schema: { $ref: "#/components/schemas/PasswordSetupRequest" } },
        },
      },
      responses: sessionResponse,
    },
  },
  "/api/v1/auth/sessions": {
    post: {
      tags: ["Authentication"],
      summary: "Cria uma sessão administrativa",
      operationId: "createAdminSession",
      requestBody: {
        required: true,
        content: {
          "application/json": { schema: { $ref: "#/components/schemas/AuthLoginRequest" } },
        },
      },
      responses: sessionResponse,
    },
  },
  "/api/v1/auth/sessions/refresh": {
    post: {
      tags: ["Authentication"],
      summary: "Rotaciona o refresh token e renova o access token",
      operationId: "refreshAdminSession",
      security: [{ refreshCookie: [] }],
      responses: sessionResponse,
    },
  },
  "/api/v1/auth/sessions/current": {
    delete: {
      tags: ["Authentication"],
      summary: "Revoga a sessão administrativa atual",
      operationId: "deleteAdminSession",
      security: [{ bearerAuth: [] }],
      responses: {
        "204": { description: "Sessão revogada." },
        "401": errorResponses["401"],
      },
    },
  },
  "/api/v1/auth/me": {
    get: {
      tags: ["Authentication"],
      summary: "Obtém identidade, perfil e permissões administrativas efetivas",
      operationId: "getCurrentAdminContext",
      security: [{ bearerAuth: [] }],
      responses: {
        "200": {
          description: "Contexto administrativo atual.",
          content: {
            "application/json": {
              schema: {
                type: "object",
                required: ["data"],
                properties: { data: { $ref: "#/components/schemas/AuthUser" } },
              },
            },
          },
        },
        "401": errorResponses["401"],
        "403": errorResponses["403"],
      },
    },
  },
  "/api/v1/auth/password": {
    patch: {
      tags: ["Authentication"],
      summary: "Altera a senha administrativa e revoga as demais sessões",
      operationId: "changeAdminPassword",
      security: [{ bearerAuth: [] }],
      requestBody: {
        required: true,
        content: {
          "application/json": { schema: { $ref: "#/components/schemas/PasswordChangeRequest" } },
        },
      },
      responses: {
        "204": { description: "Senha alterada." },
        ...errorResponses,
      },
    },
  },
} as const;

export const authSchemas = {
  LoginStateRequest: {
    type: "object",
    required: ["loginIdentifier"],
    additionalProperties: false,
    properties: { loginIdentifier: { type: "string", minLength: 1, maxLength: 160 } },
  },
  LoginState: {
    type: "object",
    required: ["loginIdentifier", "passwordStatus"],
    additionalProperties: false,
    properties: {
      loginIdentifier: { type: "string" },
      passwordStatus: { type: "string", enum: ["PENDING", "ACTIVE"] },
    },
  },
  AuthLoginRequest: {
    type: "object",
    required: ["loginIdentifier", "password"],
    additionalProperties: false,
    properties: {
      loginIdentifier: { type: "string", minLength: 1, maxLength: 160 },
      password: { type: "string", minLength: 1, maxLength: 128, format: "password" },
    },
  },
  PasswordSetupRequest: {
    type: "object",
    required: ["loginIdentifier", "newPassword"],
    additionalProperties: false,
    properties: {
      loginIdentifier: { type: "string", minLength: 1, maxLength: 160 },
      newPassword: { type: "string", minLength: 8, maxLength: 128, format: "password" },
    },
  },
  PasswordChangeRequest: {
    type: "object",
    required: ["currentPassword", "newPassword"],
    additionalProperties: false,
    properties: {
      currentPassword: { type: "string", minLength: 1, maxLength: 128, format: "password" },
      newPassword: { type: "string", minLength: 8, maxLength: 128, format: "password" },
    },
  },
} as const;
