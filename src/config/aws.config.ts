import { environment } from "./environment.js";

export const awsConfig = Object.freeze({
  enabled: environment.aws.enabled,
  region: environment.aws.region,
  secretsPrefix: environment.aws.secretsPrefix,
  bracketPreviewQueueUrl: environment.aws.bracketPreviewQueueUrl,
  bracketPreviewWorkerEnabled: environment.aws.bracketPreviewWorkerEnabled,
  bracketPreviewPollWaitSeconds: environment.aws.bracketPreviewPollWaitSeconds,
  bracketPreviewVisibilityTimeoutSeconds: environment.aws.bracketPreviewVisibilityTimeoutSeconds,
  bracketPreviewMaxReceiveCount: environment.aws.bracketPreviewMaxReceiveCount,
});
