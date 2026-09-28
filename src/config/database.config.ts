import { environment } from "./environment.js";
import { createRedactedConfig } from "./redacted-config.js";

export const databaseConfig = createRedactedConfig(
  {
    url: environment.databaseUrl,
    maxConnections: environment.databasePoolMax,
    idleTimeoutSeconds: environment.databaseIdleTimeoutSeconds,
    connectTimeoutSeconds: environment.databaseConnectTimeoutSeconds,
    shutdownTimeoutSeconds: environment.databaseShutdownTimeoutSeconds,
  },
  ["url"] as const,
);
