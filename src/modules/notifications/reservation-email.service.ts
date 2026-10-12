import {
  buildReservationAdminHtml,
  buildReservationRequesterHtml,
  buildReservationSubject,
} from "./reservation-email.template.js";
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
    buildReservationSubject(input),
    buildReservationRequesterHtml(input, mailConfig.appUrl),
  );

  if (input.type !== "PENDING") return;

  const adminRecipients = [mailConfig.coEventsEmail, mailConfig.coPresidencyEmail].filter(
    (email): email is string => Boolean(email),
  );

  if (adminRecipients.length === 0) return;

  for (const email of [...new Set(adminRecipients)]) {
    try {
      await sendBrevoEmail(
        [{ email }],
        `Nova solicitação de reserva: ${input.eventName} (${input.teamName})`,
        buildReservationAdminHtml(input, mailConfig.appUrl),
      );
    } catch (error) {
      console.error(`reservation-admin-email-failed recipient=${email}`, error);
    }
  }
}

export function sendReservationEmailSafely(input: ReservationEmailInput): void {
  void sendReservationEmail(input).catch((error: unknown) => {
    console.error("reservation-email-failed", error);
  });
}
