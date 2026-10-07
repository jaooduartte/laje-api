import { mailConfig } from "../../config/mail.config.js";

export type ReservationEmailType = "PENDING" | "APPROVED" | "REJECTED";

export interface ReservationEmailInput {
  type: ReservationEmailType;
  requesterEmail: string;
  requesterName: string;
  teamName: string;
  eventName: string;
  eventType: string;
  eventDate: string;
  reviewNotes?: string | null;
}

interface BrevoRecipient {
  email: string;
  name?: string;
}

function formatDate(date: string): string {
  const parsed = new Date(`${date}T12:00:00-03:00`);
  if (!Number.isFinite(parsed.getTime())) return date;
  return new Intl.DateTimeFormat("pt-BR", {
    timeZone: "America/Sao_Paulo",
    dateStyle: "long",
  }).format(parsed);
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function subjectFor(input: ReservationEmailInput): string {
  if (input.type === "PENDING") return `Solicitação recebida: ${input.eventName}`;
  if (input.type === "APPROVED") return `Reserva aprovada: ${input.eventName}`;
  return `Atualização sobre sua reserva: ${input.eventName}`;
}

function statusLabel(type: ReservationEmailType): string {
  if (type === "PENDING") return "Solicitação recebida";
  if (type === "APPROVED") return "Reserva aprovada";
  return "Reserva não aprovada";
}

function buildRequesterHtml(input: ReservationEmailInput): string {
  const notes = input.reviewNotes?.trim()
    ? `<p><strong>Observações:</strong> ${escapeHtml(input.reviewNotes.trim())}</p>`
    : "";

  return `<!doctype html>
<html lang="pt-BR">
  <body style="font-family:Arial,sans-serif;color:#111827;line-height:1.5">
    <h2>${escapeHtml(statusLabel(input.type))}</h2>
    <p>Olá, ${escapeHtml(input.requesterName)}.</p>
    <p>Esta é uma atualização sobre a solicitação de reserva registrada na agenda da LAJE.</p>
    <ul>
      <li><strong>Evento:</strong> ${escapeHtml(input.eventName)}</li>
      <li><strong>Atlética:</strong> ${escapeHtml(input.teamName)}</li>
      <li><strong>Tipo:</strong> ${escapeHtml(input.eventType)}</li>
      <li><strong>Data:</strong> ${escapeHtml(formatDate(input.eventDate))}</li>
    </ul>
    ${notes}
    <p>Consulte a agenda em <a href="${escapeHtml(mailConfig.appUrl)}">${escapeHtml(mailConfig.appUrl)}</a>.</p>
  </body>
</html>`;
}

function buildAdminHtml(input: ReservationEmailInput): string {
  return `<!doctype html>
<html lang="pt-BR">
  <body style="font-family:Arial,sans-serif;color:#111827;line-height:1.5">
    <h2>Nova solicitação de reserva</h2>
    <ul>
      <li><strong>Solicitante:</strong> ${escapeHtml(input.requesterName)} (${escapeHtml(input.requesterEmail)})</li>
      <li><strong>Atlética:</strong> ${escapeHtml(input.teamName)}</li>
      <li><strong>Evento:</strong> ${escapeHtml(input.eventName)}</li>
      <li><strong>Tipo:</strong> ${escapeHtml(input.eventType)}</li>
      <li><strong>Data:</strong> ${escapeHtml(formatDate(input.eventDate))}</li>
    </ul>
  </body>
</html>`;
}

async function sendBrevoEmail(
  recipients: BrevoRecipient[],
  subject: string,
  htmlContent: string,
): Promise<void> {
  if (!mailConfig.enabled) return;
  if (!mailConfig.brevoApiKey || !mailConfig.from) {
    throw new Error("Brevo mail runtime is enabled but incomplete.");
  }

  const response = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: {
      accept: "application/json",
      "api-key": mailConfig.brevoApiKey,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      sender: {
        email: mailConfig.from,
        name: mailConfig.fromName,
      },
      to: recipients,
      subject,
      htmlContent,
    }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Brevo email failed with HTTP ${response.status}: ${body.slice(0, 500)}`);
  }
}

export async function sendReservationEmail(input: ReservationEmailInput): Promise<void> {
  if (!mailConfig.enabled) return;

  await sendBrevoEmail(
    [{ email: input.requesterEmail, name: input.requesterName }],
    subjectFor(input),
    buildRequesterHtml(input),
  );

  if (input.type !== "PENDING") return;

  const adminRecipients = [
    mailConfig.coEventsEmail,
    mailConfig.coPresidencyEmail,
  ].filter((email): email is string => Boolean(email));

  if (adminRecipients.length === 0) return;

  try {
    await sendBrevoEmail(
      [...new Set(adminRecipients)].map((email) => ({ email })),
      `Nova solicitação de reserva: ${input.eventName}`,
      buildAdminHtml(input),
    );
  } catch (error) {
    console.error("reservation-admin-email-failed", error);
  }
}

export function sendReservationEmailSafely(input: ReservationEmailInput): void {
  void sendReservationEmail(input).catch((error: unknown) => {
    console.error("reservation-email-failed", error);
  });
}
