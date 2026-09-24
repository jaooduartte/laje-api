import { environment } from "./environment.js";

export const databaseConfig = Object.freeze({
  url: environment.databaseUrl,
});
