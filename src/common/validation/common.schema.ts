import { ApiError } from "../errors/api-error.js";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function requireUuid(value: unknown, field: string): string {
  if (typeof value != "string" || !UUID_PATTERN.test(value)) {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} deve ser um UUID válido.`, [
      { field, code: "INVALID_UUID", message: "UUID inválido." },
    ]);
  }
  return value;
}

export function optionalUuid(value: unknown, field: string): string | undefined {
  if (value == null || value === "") return undefined;
  return requireUuid(value, field);
}

export function requireInteger(
  value: unknown,
  field: string,
  options: { min?: number; max?: number } = {},
): number {
  const parsed = typeof value == "number" ? value : Number(value);
  if (!Number.isInteger(parsed)) {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} deve ser um número inteiro.`, [
      { field, code: "INVALID_INTEGER", message: "Número inteiro inválido." },
    ]);
  }
  if (options.min != null && parsed < options.min) {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} deve ser maior ou igual a ${options.min}.`);
  }
  if (options.max != null && parsed > options.max) {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} deve ser menor ou igual a ${options.max}.`);
  }
  return parsed;
}

export function optionalInteger(
  value: unknown,
  field: string,
  options: { min?: number; max?: number } = {},
): number | undefined {
  if (value == null || value === "") return undefined;
  return requireInteger(value, field, options);
}

export function requireString(value: unknown, field: string, maxLength = 255): string {
  if (typeof value != "string" || value.trim().length == 0 || value.length > maxLength) {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} deve ser um texto não vazio com até ${maxLength} caracteres.`);
  }
  return value.trim();
}

export function optionalString(value: unknown, field: string, maxLength = 255): string | undefined {
  if (value == null || value === "") return undefined;
  return requireString(value, field, maxLength);
}

export function optionalBoolean(value: unknown, field: string): boolean | undefined {
  if (value == null || value === "") return undefined;
  if (typeof value != "boolean") {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} deve ser booleano.`);
  }
  return value;
}

export function requireEnum<const Values extends readonly string[]>(
  value: unknown,
  field: string,
  values: Values,
): Values[number] {
  if (typeof value != "string" || !values.includes(value)) {
    throw new ApiError(422, "VALIDATION_ERROR", `Valor inválido para ${field}.`, [
      { field, code: "INVALID_ENUM", message: `Valores aceitos: ${values.join(", ")}.` },
    ]);
  }
  return value as Values[number];
}

export function optionalEnum<const Values extends readonly string[]>(
  value: unknown,
  field: string,
  values: Values,
): Values[number] | undefined {
  if (value == null || value === "") return undefined;
  return requireEnum(value, field, values);
}

export function requireRecord(value: unknown, message = "Payload JSON inválido."): Record<string, unknown> {
  if (!value || typeof value != "object" || Array.isArray(value)) {
    throw new ApiError(422, "VALIDATION_ERROR", message);
  }
  return value as Record<string, unknown>;
}

export function parseDate(value: unknown, field: string): string | undefined {
  if (value == null || value === "") return undefined;
  if (typeof value != "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} deve usar o formato YYYY-MM-DD.`);
  }
  const date = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== value) {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} contém uma data inválida.`);
  }
  return value;
}

export function parsePagination(query: Record<string, unknown>) {
  const page = optionalInteger(query.page, "page", { min: 1 }) ?? 1;
  const pageSize = optionalInteger(query.pageSize, "pageSize", { min: 1, max: 100 }) ?? 50;
  return { page, pageSize, offset: (page - 1) * pageSize };
}
