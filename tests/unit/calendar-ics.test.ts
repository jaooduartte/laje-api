import assert from "node:assert/strict";
import test from "node:test";

import {
  buildCalendarDocument,
  resolveCalendarDescription,
  resolveETag,
  resolveMatchCalendarTitle,
  resolveScheduledSessionDateTime,
} from "../../src/modules/calendar-subscription/calendar-ics.js";

test("calendar helper preserves LAJE match naming and Sao Paulo session timestamps", () => {
  assert.equal(
    resolveMatchCalendarTitle("Vôlei", "Feminino", "Engênios", "AFA"),
    "LAJE · Vôlei Feminino — Engênios x AFA",
  );
  assert.equal(
    resolveScheduledSessionDateTime("2026-10-11", "13:30:00"),
    "2026-10-11T16:30:00.000Z",
  );
  assert.equal(resolveScheduledSessionDateTime("invalid", "13:30:00"), null);
  assert.equal(
    resolveCalendarDescription(["Interlaje", null, "Feminino", undefined, "Agenda"]),
    "Interlaje\nFeminino\nAgenda",
  );
});

test("calendar helper emits deterministic ICS and ETag", () => {
  const document = buildCalendarDocument([
    {
      uid: "match-1@laje.app",
      title: "LAJE · Vôlei Feminino — A x B",
      description: "Interlaje\nFeminino",
      location: "Ginásio • Quadra 1",
      startTime: "2026-10-11T15:00:00.000Z",
      endTime: "2026-10-11T16:00:00.000Z",
      updatedAt: "2026-10-07T18:00:00.000Z",
    },
  ]);

  assert.match(document, /BEGIN:VCALENDAR/);
  assert.match(document, /BEGIN:VEVENT/);
  assert.match(document, /TZID:America\/Sao_Paulo/);
  assert.match(document, /UID:match-1@laje.app/);
  assert.match(document, /LOCATION:Ginásio • Quadra 1/);
  assert.match(resolveETag(document), /^"[0-9a-f]{64}"$/);
  assert.equal(resolveETag(document), resolveETag(document));
});
