import type { ReservationEmailInput } from "./reservation-email.service.js";

// Visual layout mirrored from laje/supabase/functions/send-reservation-email/index.ts.
// Keep both delivery backends visually equivalent when changing either version.
const LEAGUE_EVENT_TYPE_LABELS: Record<string, string> = {
  HH: "HH",
  OPEN_BAR: "Open Bar",
  CHAMPIONSHIP: "Campeonato",
  LAJE_EVENT: "Evento LAJE",
};

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/\x27/g, "&#039;");
}

function formatDate(dateStr: string): string {
  const [year, month, day] = dateStr.split("-");
  const months = [
    "janeiro", "fevereiro", "março", "abril", "maio", "junho",
    "julho", "agosto", "setembro", "outubro", "novembro", "dezembro",
  ];
  return `${day} de ${months[Number(month) - 1]} de ${year}`;
}

export function buildReservationSubject(payload: ReservationEmailInput): string {
  switch (payload.type) {
    case "PENDING":
      return `Solicitação recebida: ${payload.eventName}`;
    case "APPROVED":
      return `Reserva aprovada: ${payload.eventName}`;
    case "REJECTED":
      return `Atualização sobre sua reserva: ${payload.eventName}`;
  }
}

function iconImg(svg: string): string {
  return `<img src="data:image/svg+xml,${encodeURIComponent(svg)}" width="18" height="18" alt="" style="display:inline-block;vertical-align:middle;margin-right:6px;">`;
}

const ICON_CLOCK = `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#6b7280" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>`;
const ICON_CHECK_CIRCLE = `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#16a34a" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="9 12 11 14 15 10"/></svg>`;
const ICON_X_CIRCLE = `<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#dc2626" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>`;

function buildStatusBlock(payload: ReservationEmailInput): string {
  switch (payload.type) {
    case "PENDING":
      return `
        <div style="background:#f3f4f6;border-radius:12px;padding:20px 24px;margin-bottom:24px;border-left:4px solid #6b7280;">
          <p style="margin:0 0 4px 0;font-size:12px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#6b7280;">Status</p>
          <p style="margin:0;font-size:16px;font-weight:700;color:#374151;">${iconImg(ICON_CLOCK)}Em análise</p>
          <p style="margin:8px 0 0 0;font-size:14px;color:#6b7280;line-height:1.5;">
            Recebemos sua solicitação e nossa equipe irá analisá-la em breve. Você será notificado por email assim que houver uma atualização.
          </p>
        </div>
      `;
    case "APPROVED":
      return `
        <div style="background:#f0fdf4;border-radius:12px;padding:20px 24px;margin-bottom:24px;border-left:4px solid #16a34a;">
          <p style="margin:0 0 4px 0;font-size:12px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#16a34a;">Status</p>
          <p style="margin:0;font-size:16px;font-weight:700;color:#15803d;">${iconImg(ICON_CHECK_CIRCLE)}Reserva aprovada!</p>
          <p style="margin:8px 0 0 0;font-size:14px;color:#166534;line-height:1.5;">
            Sua reserva foi aprovada e o evento já está publicado no calendário da liga. Boa sorte no evento!
          </p>
        </div>
      `;
    case "REJECTED":
      return `
        <div style="background:#fef2f2;border-radius:12px;padding:20px 24px;margin-bottom:24px;border-left:4px solid #dc2626;">
          <p style="margin:0 0 4px 0;font-size:12px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#dc2626;">Status</p>
          <p style="margin:0;font-size:16px;font-weight:700;color:#b91c1c;">${iconImg(ICON_X_CIRCLE)}Reserva não aprovada</p>
          <p style="margin:8px 0 0 0;font-size:14px;color:#991b1b;line-height:1.5;">
            Infelizmente não foi possível aprovar sua solicitação de reserva.
          </p>
          ${payload.reviewNotes ? `
          <div style="margin-top:12px;padding:12px 16px;background:#fee2e2;border-radius:8px;">
            <p style="margin:0 0 4px 0;font-size:11px;font-weight:700;letter-spacing:0.06em;text-transform:uppercase;color:#b91c1c;">Motivo</p>
            <p style="margin:0;font-size:14px;color:#7f1d1d;line-height:1.5;">${escapeHtml(payload.reviewNotes ?? "")}</p>
          </div>
          ` : ""}
        </div>
      `;
  }
}

export function buildReservationRequesterHtml(payload: ReservationEmailInput, appUrl: string): string {
  const normalizedAppUrl = appUrl.replace(/\/+$/, "");
  const eventTypeLabel = LEAGUE_EVENT_TYPE_LABELS[payload.eventType] ?? payload.eventType;
  const formattedDate = formatDate(payload.eventDate);
  const statusBlock = buildStatusBlock(payload);

  return `
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${escapeHtml(buildReservationSubject(payload))}</title>
</head>
<body style="margin:0;padding:0;background-color:#f4f4f5;font-family:'Inter',Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;padding:32px 16px;">
    <tr>
      <td align="center">
        <table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;">

          <!-- HEADER -->
          <tr>
            <td>
              <div style="background:#dc2626;border-radius:16px 16px 0 0;padding:24px 32px;text-align:center;">
                <img
                  src="${escapeHtml(normalizedAppUrl)}/logo.png"
                  alt="LAJE"
                  width="56"
                  height="56"
                  style="display:block;margin:0 auto 12px auto;border-radius:12px;object-fit:contain;"
                />
                <p style="margin:0;font-size:11px;font-weight:700;letter-spacing:0.14em;text-transform:uppercase;color:rgba(255,255,255,0.7);">Liga das Atléticas de Joinville</p>
                <p style="margin:4px 0 0 0;font-size:22px;font-weight:800;color:#ffffff;letter-spacing:-0.02em;">Calendário de Eventos</p>
              </div>
            </td>
          </tr>

          <!-- BODY -->
          <tr>
            <td style="background:#ffffff;padding:32px;">

              <p style="margin:0 0 4px 0;font-size:13px;color:#6b7280;">Olá, <strong>${escapeHtml(payload.requesterName)}</strong>!</p>
              <p style="margin:0 0 24px 0;font-size:13px;color:#6b7280;">Aqui está a atualização sobre a solicitação de reserva da <strong>${escapeHtml(payload.teamName)}</strong>.</p>

              ${statusBlock}

              <!-- EVENT DETAILS CARD -->
              <div style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:12px;padding:20px 24px;margin-bottom:24px;">
                <p style="margin:0 0 16px 0;font-size:12px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#9ca3af;">Detalhes do evento</p>

                <table width="100%" cellpadding="0" cellspacing="0">
                  <tr>
                    <td style="padding-bottom:12px;vertical-align:top;width:50%;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Evento</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${escapeHtml(payload.eventName)}</p>
                    </td>
                    <td style="padding-bottom:12px;vertical-align:top;width:50%;padding-left:16px;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Tipo</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${escapeHtml(eventTypeLabel)}</p>
                    </td>
                  </tr>
                  <tr>
                    <td style="vertical-align:top;width:50%;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Data solicitada</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${formattedDate}</p>
                    </td>
                    <td style="vertical-align:top;width:50%;padding-left:16px;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Atlética</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${escapeHtml(payload.teamName)}</p>
                    </td>
                  </tr>
                </table>
              </div>

              <p style="margin:0;font-size:13px;color:#9ca3af;line-height:1.6;">
                Em caso de dúvidas, entre em contato com a organização da liga.
              </p>
            </td>
          </tr>

          <!-- FOOTER -->
          <tr>
            <td style="background:#f9fafb;border-radius:0 0 16px 16px;padding:20px 32px;border-top:1px solid #e5e7eb;text-align:center;">
              <p style="margin:0;font-size:12px;color:#9ca3af;">
                Liga das Atléticas de Joinville · <a href="${escapeHtml(normalizedAppUrl)}" style="color:#dc2626;text-decoration:none;">${escapeHtml(normalizedAppUrl.replace(/^https?:\/\//, ""))}</a>
              </p>
              <p style="margin:4px 0 0 0;font-size:11px;color:#d1d5db;">Este email foi enviado automaticamente. Não responda a este email.</p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>
  `.trim();
}

export function buildReservationAdminHtml(payload: ReservationEmailInput, appUrl: string): string {
  const normalizedAppUrl = appUrl.replace(/\/+$/, "");
  const eventTypeLabel = LEAGUE_EVENT_TYPE_LABELS[payload.eventType] ?? payload.eventType;
  const formattedDate = formatDate(payload.eventDate);

  return `
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Nova solicitação de reserva</title>
</head>
<body style="margin:0;padding:0;background-color:#f4f4f5;font-family:'Inter',Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;padding:32px 16px;">
    <tr>
      <td align="center">
        <table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;">

          <!-- HEADER -->
          <tr>
            <td>
              <div style="background:#dc2626;border-radius:16px 16px 0 0;padding:24px 32px;text-align:center;">
                <img
                  src="${escapeHtml(normalizedAppUrl)}/logo.png"
                  alt="LAJE"
                  width="56"
                  height="56"
                  style="display:block;margin:0 auto 12px auto;border-radius:12px;object-fit:contain;"
                />
                <p style="margin:0;font-size:11px;font-weight:700;letter-spacing:0.14em;text-transform:uppercase;color:rgba(255,255,255,0.7);">Liga das Atléticas de Joinville</p>
                <p style="margin:4px 0 0 0;font-size:22px;font-weight:800;color:#ffffff;letter-spacing:-0.02em;">Nova Solicitação de Reserva</p>
              </div>
            </td>
          </tr>

          <!-- BODY -->
          <tr>
            <td style="background:#ffffff;padding:32px;">

              <div style="background:#fef3c7;border-radius:12px;padding:20px 24px;margin-bottom:24px;border-left:4px solid #f59e0b;">
                <p style="margin:0 0 4px 0;font-size:12px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#d97706;">Ação necessária</p>
                <p style="margin:0;font-size:15px;font-weight:700;color:#92400e;">Há uma nova solicitação aguardando análise.</p>
                <p style="margin:8px 0 0 0;font-size:14px;color:#b45309;line-height:1.5;">
                  Acesse o painel administrativo para aprovar ou rejeitar o pedido.
                </p>
              </div>

              <!-- EVENT DETAILS CARD -->
              <div style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:12px;padding:20px 24px;margin-bottom:24px;">
                <p style="margin:0 0 16px 0;font-size:12px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#9ca3af;">Detalhes da solicitação</p>

                <table width="100%" cellpadding="0" cellspacing="0">
                  <tr>
                    <td style="padding-bottom:12px;vertical-align:top;width:50%;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Evento</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${escapeHtml(payload.eventName)}</p>
                    </td>
                    <td style="padding-bottom:12px;vertical-align:top;width:50%;padding-left:16px;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Tipo</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${escapeHtml(eventTypeLabel)}</p>
                    </td>
                  </tr>
                  <tr>
                    <td style="padding-bottom:12px;vertical-align:top;width:50%;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Data solicitada</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${formattedDate}</p>
                    </td>
                    <td style="padding-bottom:12px;vertical-align:top;width:50%;padding-left:16px;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Atlética</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${escapeHtml(payload.teamName)}</p>
                    </td>
                  </tr>
                  <tr>
                    <td style="vertical-align:top;width:50%;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Solicitante</p>
                      <p style="margin:0;font-size:15px;font-weight:700;color:#111827;">${escapeHtml(payload.requesterName)}</p>
                    </td>
                    <td style="vertical-align:top;width:50%;padding-left:16px;">
                      <p style="margin:0 0 2px 0;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;color:#9ca3af;">Email do solicitante</p>
                      <p style="margin:0;font-size:14px;font-weight:600;color:#111827;">${escapeHtml(payload.requesterEmail)}</p>
                    </td>
                  </tr>
                </table>
              </div>

              <p style="margin:0;font-size:13px;color:#9ca3af;line-height:1.6;">
                Acesse <a href="${escapeHtml(normalizedAppUrl)}/admin" style="color:#dc2626;text-decoration:none;">${escapeHtml(normalizedAppUrl)}/admin</a> para gerenciar as solicitações pendentes.
              </p>
            </td>
          </tr>

          <!-- FOOTER -->
          <tr>
            <td style="background:#f9fafb;border-radius:0 0 16px 16px;padding:20px 32px;border-top:1px solid #e5e7eb;text-align:center;">
              <p style="margin:0;font-size:12px;color:#9ca3af;">
                Liga das Atléticas de Joinville · <a href="${escapeHtml(normalizedAppUrl)}" style="color:#dc2626;text-decoration:none;">${escapeHtml(normalizedAppUrl.replace(/^https?:\/\//, ""))}</a>
              </p>
              <p style="margin:4px 0 0 0;font-size:11px;color:#d1d5db;">Este email foi enviado automaticamente. Não responda a este email.</p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>
  `.trim();
}
