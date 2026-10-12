import assert from "node:assert/strict";
import test from "node:test";

import {
  buildReservationAdminHtml,
  buildReservationRequesterHtml,
  buildReservationSubject,
} from "../../src/modules/notifications/reservation-email.template.js";
import type { ReservationEmailInput } from "../../src/modules/notifications/reservation-email.service.js";

const original: ReservationEmailInput = {
  type: "PENDING",
  requesterEmail: "solicitante@example.com",
  requesterName: "Solicitante",
  teamName: "Engênios",
  eventName: "TESTE LAJE-126",
  eventType: "HH",
  eventDate: "2026-10-20",
};

test("requester notification preserves legacy LAJE branding and details", () => {
  const html = buildReservationRequesterHtml(original, "https://laje-tcc.vercel.app/");
  assert.match(html, /background:#dc2626/);
  assert.match(html, /src="https:\/\/laje-tcc\.vercel\.app\/logo\.png"/);
  assert.match(html, /Calendário de Eventos/);
  assert.match(html, /Em análise/);
  assert.match(html, /Detalhes do evento/);
  assert.match(html, /20 de outubro de 2026/);
  assert.match(html, /Engênios/);
  assert.match(html, /href="https:\/\/laje-tcc\.vercel\.app"/);
  assert.equal(buildReservationSubject(original), "Solicitação recebida: TESTE LAJE-126");
});

test("approval and rejection reuse the same status cards and subjects as Supabase", () => {
  const approved = buildReservationRequesterHtml({ ...original, type: "APPROVED" }, "https://laje-tcc.vercel.app");
  assert.match(approved, /Reserva aprovada!/);
  assert.match(approved, /Sua reserva foi aprovada e o evento já está publicado/);
  assert.equal(buildReservationSubject({ ...original, type: "APPROVED" }), "Reserva aprovada: TESTE LAJE-126");
  const rejected = buildReservationRequesterHtml({ ...original, type: "REJECTED", reviewNotes: "Data ocupada" }, "https://laje-tcc.vercel.app");
  assert.match(rejected, /Reserva não aprovada/);
  assert.match(rejected, /Motivo/);
  assert.match(rejected, /Data ocupada/);
  assert.equal(buildReservationSubject({ ...original, type: "REJECTED" }), "Atualização sobre sua reserva: TESTE LAJE-126");
});

test("admin notification preserves legacy actionable banner and management link", () => {
  const html = buildReservationAdminHtml(original, "https://laje-tcc.vercel.app");
  assert.match(html, /Nova Solicitação de Reserva/);
  assert.match(html, /Ação necessária/);
  assert.match(html, /Detalhes da solicitação/);
  assert.match(html, /Solicitante/);
  assert.match(html, /solicitante@example\.com/);
  assert.match(html, /href="https:\/\/laje-tcc\.vercel\.app\/admin"/);
});

test("HTML-escapes input fields and review notes without modifying the visible layout", () => {
  const malicious = { ...original, type: "REJECTED" as const, eventName: "<script>alert(1)</script>", requesterName: "<b>Fulano</b>", reviewNotes: "<img src=x onerror=alert(1)>" };
  const requester = buildReservationRequesterHtml(malicious, "https://laje-tcc.vercel.app");
  const admin = buildReservationAdminHtml(malicious, "https://laje-tcc.vercel.app");
  assert.match(requester, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(requester, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(requester, /&lt;b&gt;Fulano&lt;\/b&gt;/);
  assert.match(admin, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.doesNotMatch(requester, /<script>|<img src=x/);
  assert.doesNotMatch(admin, /<script>/);
});

