import { inspect } from "node:util";

const REDACTED_VALUE = "[REDACTED]";

type ConfigRecord = Record<string, unknown>;

export function createRedactedConfig<T extends ConfigRecord, K extends keyof T>(
  value: T,
  sensitiveKeys: readonly K[],
): Readonly<T> {
  const sensitiveKeySet = new Set<keyof T>(sensitiveKeys);

  const sanitize = (): ConfigRecord =>
    Object.fromEntries(
      Object.entries(value).map(([key, fieldValue]) => [
        key,
        sensitiveKeySet.has(key as keyof T) && fieldValue !== undefined
          ? REDACTED_VALUE
          : fieldValue,
      ]),
    );

  return Object.freeze({
    ...value,
    toJSON: sanitize,
    [inspect.custom]: sanitize,
  }) as Readonly<T>;
}
