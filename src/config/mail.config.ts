import { environment } from "./environment.js";

export const mailConfig = Object.freeze({
  enabled: environment.mail.enabled,
  host: environment.mail.host,
  port: environment.mail.port,
  secure: environment.mail.secure,
  user: environment.mail.user,
  password: environment.mail.password,
  from: environment.mail.from,
});
