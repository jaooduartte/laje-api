import assert from "node:assert/strict";
import test from "node:test";

import { openApiDocument } from "../../src/openapi/openapi.document.js";

const expectedPlannedOperations = [
  ["/api/v1/auth/sessions", "post"],
  ["/api/v1/auth/sessions/refresh", "post"],
  ["/api/v1/auth/sessions/current", "delete"],
  ["/api/v1/auth/me", "get"],
  ["/api/v1/matches", "get"],
  ["/api/v1/matches/{matchId}", "get"],
  ["/api/v1/matches/{matchId}/start", "post"],
  ["/api/v1/matches/{matchId}/scoreboard", "patch"],
  ["/api/v1/matches/{matchId}/finish", "post"],
  ["/api/v1/championships", "get"],
  ["/api/v1/championships/{championshipId}", "get"],
  ["/api/v1/championships/{championshipId}/standings", "get"],
  ["/api/v1/championships/{championshipId}/calendar", "get"],
] as const;

test("priority flows are present in OpenAPI and explicitly marked as planned", () => {
  for (const [path, method] of expectedPlannedOperations) {
    const pathItem = openApiDocument.paths[path];
    assert.ok(pathItem, `${path} should exist`);

    const operation = pathItem[method];
    assert.ok(operation, `${method.toUpperCase()} ${path} should exist`);
    assert.equal(operation["x-implementation-status"], "planned");
  }
});

test("administrative commands require bearer authentication while public reads do not", () => {
  assert.deepEqual(openApiDocument.paths["/api/v1/auth/me"].get.security, [
    { bearerAuth: [] },
  ]);
  assert.deepEqual(
    openApiDocument.paths["/api/v1/matches/{matchId}/scoreboard"].patch.security,
    [{ bearerAuth: [] }],
  );

  assert.equal("security" in openApiDocument.paths["/api/v1/matches"].get, false);
  assert.equal(
    "security" in
      openApiDocument.paths["/api/v1/championships/{championshipId}/standings"].get,
    false,
  );
});

test("authentication contract defines bearer access and refresh-cookie transport", () => {
  assert.equal(openApiDocument.components.securitySchemes.bearerAuth.scheme, "bearer");
  assert.equal(openApiDocument.components.securitySchemes.refreshCookie.in, "cookie");
  assert.equal(
    openApiDocument.components.securitySchemes.refreshCookie.name,
    "laje_refresh_token",
  );
  assert.deepEqual(
    openApiDocument.paths["/api/v1/auth/sessions/refresh"].post.security,
    [{ refreshCookie: [] }],
  );
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
    openApiDocument.paths["/api/v1/championships/{championshipId}/standings"].get
      .parameters;
  const calendarParameters =
    openApiDocument.paths["/api/v1/championships/{championshipId}/calendar"].get
      .parameters;

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
