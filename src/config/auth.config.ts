import { environment } from "./environment.js";

export const authConfig = Object.freeze({
  enabled: environment.auth.enabled,
  jwtSecret: environment.auth.jwtSecret,
  jwtExpiresIn: environment.auth.jwtExpiresIn,
});
