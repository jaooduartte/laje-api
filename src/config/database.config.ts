import { environment } from "./environment.js";
import { createRedactedConfig } from "./redacted-config.js";

export const databaseConfig = createRedactedConfig(
  {
    url: environment.databaseUrl,
  },
  ["url"] as const,
);
