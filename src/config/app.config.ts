import { environment } from "./environment.js";

export const appConfig = Object.freeze({
  environment: environment.nodeEnv,
  port: environment.port,
  corsOrigins: environment.corsOrigins,
});
