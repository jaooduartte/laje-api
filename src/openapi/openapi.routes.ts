import { Router } from "express";

import type { NodeEnvironment } from "../config/environment.js";
import { openApiDocument } from "./openapi.document.js";

const SWAGGER_UI_VERSION = "5.17.14";

const swaggerUiHtml = `<!doctype html>
<html lang="pt-BR">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>LAJE API — OpenAPI</title>
    <link
      rel="stylesheet"
      href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@${SWAGGER_UI_VERSION}/swagger-ui.css"
    />
  </head>
  <body>
    <div id="swagger-ui"></div>
    <noscript>
      JavaScript é necessário para o Swagger UI. A especificação continua disponível em
      <a href="/api-docs/openapi.json">/api-docs/openapi.json</a>.
    </noscript>
    <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@${SWAGGER_UI_VERSION}/swagger-ui-bundle.js"></script>
    <script>
      window.onload = () => {
        window.ui = SwaggerUIBundle({
          url: "/api-docs/openapi.json",
          dom_id: "#swagger-ui",
          deepLinking: true,
          displayRequestDuration: true,
        });
      };
    </script>
  </body>
</html>
`;

export function isApiDocumentationEnabled(environment: NodeEnvironment): boolean {
  return environment === "development";
}

export function createOpenApiRouter(): Router {
  const router = Router();

  router.get("/", (_request, response) => {
    response.set("Cache-Control", "no-store");
    response.status(200).type("html").send(swaggerUiHtml);
  });

  router.get("/openapi.json", (_request, response) => {
    response.set("Cache-Control", "no-store");
    response.status(200).json(openApiDocument);
  });

  return router;
}
