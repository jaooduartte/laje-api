import { environment } from "./environment.js";

export const awsConfig = Object.freeze({
  enabled: environment.aws.enabled,
  region: environment.aws.region,
  secretsPrefix: environment.aws.secretsPrefix,
});
