import { createHash } from "node:crypto";

export interface CalendarFeedEvent {
  uid: string;
  title: string;
  description: string;
  location: string | null;
  startTime: string;
  endTime: string;
  updatedAt: string;
}

export function resolveMatchCalendarTitle(
  sportName: string,
  naipeLabel: string,
  homeTeam: string,
  awayTeam: string,
): string {
  return `LAJE · ${sportName} ${naipeLabel} — ${homeTeam} x ${awayTeam}`;
}

export function resolveCalendarDescription(
  descriptionParts: Array<string | null | undefined>,
): string {
  return descriptionParts.filter((value): value is string => Boolean(value)).join("\n");
}

const scheduledDatePattern = /^\d{4}-\d{2}-\d{2}$/;
const scheduledTimePattern = /^\d{2}:\d{2}(?::\d{2}(?:\.\d{1,6})?)?$/;

export function resolveScheduledSessionDateTime(
  scheduledDate: string | null,
  scheduledTime: string | null,
): string | null {
  if (
    !scheduledDate ||
    !scheduledTime ||
    !scheduledDatePattern.test(scheduledDate) ||
    !scheduledTimePattern.test(scheduledTime)
  ) {
    return null;
  }

  const dateTime = new Date(`${scheduledDate}T${scheduledTime}-03:00`);
  return Number.isFinite(dateTime.getTime()) ? dateTime.toISOString() : null;
}

function escapeIcsText(value: string): string {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r?\n/g, "\\n");
}

function formatIcsDateTime(value: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) {
    throw new Error("Invalid calendar timestamp.");
  }

  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Sao_Paulo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}${values.month}${values.day}T${values.hour}${values.minute}${values.second}`;
}

function formatIcsUtcDateTime(value: string): string {
  return new Date(value)
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
}

function foldIcsLine(line: string): string {
  if (line.length <= 75) return line;
  const chunks: string[] = [];
  for (let start = 0; start < line.length; start += 74) {
    const chunk = line.slice(start, start + 74);
    chunks.push(chunks.length === 0 ? chunk : ` ${chunk}`);
  }
  return chunks.join("\r\n");
}

export function buildCalendarDocument(events: CalendarFeedEvent[]): string {
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//LAJE//Agenda de Jogos//PT-BR",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "X-WR-CALNAME:LAJE - Agenda de Jogos",
    "X-WR-TIMEZONE:America/Sao_Paulo",
    "BEGIN:VTIMEZONE",
    "TZID:America/Sao_Paulo",
    "X-LIC-LOCATION:America/Sao_Paulo",
    "BEGIN:STANDARD",
    "TZOFFSETFROM:-0300",
    "TZOFFSETTO:-0300",
    "TZNAME:BRT",
    "DTSTART:19700101T000000",
    "END:STANDARD",
    "END:VTIMEZONE",
    ...events.flatMap((event) => [
      "BEGIN:VEVENT",
      `UID:${event.uid}`,
      `DTSTAMP:${formatIcsUtcDateTime(event.updatedAt)}`,
      `LAST-MODIFIED:${formatIcsUtcDateTime(event.updatedAt)}`,
      `DTSTART;TZID=America/Sao_Paulo:${formatIcsDateTime(event.startTime)}`,
      `DTEND;TZID=America/Sao_Paulo:${formatIcsDateTime(event.endTime)}`,
      `SUMMARY:${escapeIcsText(event.title)}`,
      `DESCRIPTION:${escapeIcsText(event.description)}`,
      ...(event.location ? [`LOCATION:${escapeIcsText(event.location)}`] : []),
      "END:VEVENT",
    ]),
    "END:VCALENDAR",
  ];
  return `${lines.map(foldIcsLine).join("\r\n")}\r\n`;
}

export function resolveETag(content: string): string {
  return `"${createHash("sha256").update(content, "utf8").digest("hex")}"`;
}
