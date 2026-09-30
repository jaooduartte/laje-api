import assert from "node:assert/strict";
import test from "node:test";

import { openApiDocument } from "../../src/openapi/openapi.document.js";

const implementedSportsCoreOperations = [
  ["/api/v1/matches", "get"],
  ["/api/v1/matches/{matchId}", "get"],
  ["/api/v1/matches/{matchId}/start", "post"],
  ["/api/v1/matches/{matchId}/scoreboard", "patch"],
  ["/api/v1/matches/{matchId}/finish", "post"],
  ["/api/v1/matches/{matchId}/return-to-scheduled", "post"],
  ["/api/v1/championships", "get"],
  ["/api/v1/championships/{championshipId}", "get"],
  ["/api/v1/championships/{championshipId}/standings", "get"],
  ["/api/v1/championships/{championshipId}/calendar", "get"],
  ["/api/v1/championships/{championshipId}/seasons/{seasonYear}", "put"],
  ["/api/v1/championships/{championshipId}/seasons/advance", "post"],
  ["/api/v1/championships/{championshipId}/seasons/{seasonYear}/reset", "post"],
] as const;

const implementedAuthenticationOperations = [
  ["/api/v1/auth/login-state", "post"],
  ["/api/v1/auth/password-setup", "post"],
  ["/api/v1/auth/sessions", "post"],
  ["/api/v1/auth/sessions/refresh", "post"],
  ["/api/v1/auth/sessions/current", "delete"],
  ["/api/v1/auth/me", "get"],
  ["/api/v1/auth/password", "patch"],
] as const;

function operationStatus(path: string, method: string): string | undefined {
  const paths = openApiDocument.paths as unknown as Record<
    string,
    Record<string, { "x-implementation-status"?: string }>
  >;
  const operation = paths[path]?.[method];
  assert.ok(operation, `${method.toUpperCase()} ${path} should exist`);
  return operation["x-implementation-status"];
}

test("LAJE-86 sports core priority operations are implemented", () => {
  for (const [path, method] of implementedSportsCoreOperations) {
    assert.equal(operationStatus(path, method), "implemented");
  }
});

test("LAJE-85 authentication operations remain implemented rather than planned", () => {
  for (const [path, method] of implementedAuthenticationOperations) {
    assert.notEqual(operationStatus(path, method), "planned");
  }
});

test("administrative commands require bearer authentication while public reads do not", () => {
  assert.deepEqual(openApiDocument.paths["/api/v1/auth/me"].get.security, [{ bearerAuth: [] }]);
  assert.deepEqual(openApiDocument.paths["/api/v1/matches/{matchId}/scoreboard"].patch.security, [
    { bearerAuth: [] },
  ]);
  assert.deepEqual(
    openApiDocument.paths["/api/v1/championships/{championshipId}/seasons/advance"].post.security,
    [{ bearerAuth: [] }],
  );

  assert.equal("security" in openApiDocument.paths["/api/v1/matches"].get, false);
  assert.equal(
    "security" in openApiDocument.paths["/api/v1/championships/{championshipId}/standings"].get,
    false,
  );
});

test("authentication contract defines bearer access and refresh-cookie transport", () => {
  assert.equal(openApiDocument.components.securitySchemes.bearerAuth.scheme, "bearer");
  assert.equal(openApiDocument.components.securitySchemes.refreshCookie.in, "cookie");
  assert.equal(openApiDocument.components.securitySchemes.refreshCookie.name, "laje_refresh_token");
  assert.deepEqual(openApiDocument.paths["/api/v1/auth/sessions/refresh"].post.security, [
    { refreshCookie: [] },
  ]);
});

test("priority DTOs and domain enums are versioned in the OpenAPI document", () => {
  const schemas = openApiDocument.components.schemas;

  assert.ok(schemas.AuthSession);
  assert.ok(schemas.AdminContext);
  assert.ok(schemas.MatchDto);
  assert.ok(schemas.ScoreboardUpdateRequest);
  assert.ok(schemas.ChampionshipDto);
  assert.ok(schemas.StandingDto);

  assert.deepEqual(schemas.MatchStatus.enum, ["SCHEDULED", "LIVE", "FINISHED"]);
  assert.deepEqual(schemas.MatchNaipe.enum, ["MASCULINO", "FEMININO", "MISTO"]);
  assert.deepEqual(schemas.ChampionshipStatus.enum, [
    "PLANNING",
    "UPCOMING",
    "REVIEW",
    "IN_PROGRESS",
    "FINISHED",
  ]);
});

test("standings and calendar require an explicit season year", () => {
  const standingsParameters =
    openApiDocument.paths["/api/v1/championships/{championshipId}/standings"].get.parameters;
  const calendarParameters =
    openApiDocument.paths["/api/v1/championships/{championshipId}/calendar"].get.parameters;

  const standingsSeason = standingsParameters.find(
    (parameter) => "name" in parameter && parameter.name === "seasonYear",
  );
  const calendarSeason = calendarParameters.find(
    (parameter) => "name" in parameter && parameter.name === "seasonYear",
  );

  assert.ok(standingsSeason && "required" in standingsSeason);
  assert.equal(standingsSeason.required, true);
  assert.ok(calendarSeason && "required" in calendarSeason);
  assert.equal(calendarSeason.required, true);
});
