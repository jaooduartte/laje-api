import { setTimeout as sleep } from "node:timers/promises";

/** Native Secrets Manager AWSCURRENT-label event; no secret values appear in this payload. */
export function isExpectedRotationEvent(event, config) {
  return (
    event?.source === "aws.secretsmanager" &&
    event?.["detail-type"] === "Secret Label Updated" &&
    event?.account === config.accountId &&
    event?.region === config.region &&
    event?.detail?.labelUpdated === "AWSCURRENT" &&
    typeof event?.detail?.versionId === "string" &&
    event.detail.versionId.length > 0 &&
    Array.isArray(event.resources) &&
    event.resources.includes(config.secretArn)
  );
}

function secretVersionIsCurrent(secret, versionId) {
  const stages = secret.VersionIdsToStages?.[versionId] ?? [];
  return stages.includes("AWSCURRENT");
}

function taskIsFresh(task, changedAt) {
  return (
    task?.lastStatus === "RUNNING" &&
    task?.healthStatus !== "UNHEALTHY" &&
    task?.startedAt instanceof Date &&
    task.startedAt.getTime() > changedAt.getTime()
  );
}

export async function handleRotation(event, deps, config) {
  if (!isExpectedRotationEvent(event, config)) {
    return { outcome: "ignored", reason: "unrelated-event" };
  }

  const secret = await deps.describeSecret(config.secretArn);
  if (secret.ARN !== config.secretArn || !secretVersionIsCurrent(secret, event.detail.versionId)) {
    return { outcome: "ignored", reason: "not-current-version" };
  }
  const changedAt = secret.LastChangedDate;
  if (!(changedAt instanceof Date) || Number.isNaN(changedAt.getTime())) {
    throw new Error("Missing LastChangedDate for the RDS managed secret.");
  }

  async function currentState() {
    const service = await deps.describeService(config.cluster, config.service);
    if (service?.serviceName !== config.service || service?.status !== "ACTIVE") {
      throw new Error("Target ECS service is unavailable.");
    }
    if (service.desiredCount === 0) return { service, tasks: [] };
    const taskArns = await deps.listTasks(config.cluster, config.service);
    const tasks = taskArns.length ? await deps.describeTasks(config.cluster, taskArns) : [];
    return { service, tasks };
  }

  let state = await currentState();
  if (state.service.desiredCount === 0) {
    return { outcome: "ignored", reason: "staging-suspended" };
  }

  // Reserved Lambda concurrency=1 prevents simultaneous handler executions.
  // For a still-running deployment, wait rather than launch another one.
  if (state.service.deployments?.some((d) => d.rolloutState === "IN_PROGRESS")) {
    await deps.waitForStable(config.cluster, config.service);
    state = await currentState();
  }

  const isFresh = (current) =>
    current.service.runningCount === current.service.desiredCount &&
    current.tasks.length === current.service.desiredCount &&
    current.tasks.every((task) => taskIsFresh(task, changedAt));

  if (isFresh(state)) return { outcome: "ignored", reason: "already-updated" };

  // Check AWSCURRENT again in case another rotation occurred during an ECS deployment.
  const latest = await deps.describeSecret(config.secretArn);
  if (!secretVersionIsCurrent(latest, event.detail.versionId)) {
    return { outcome: "ignored", reason: "superseded-rotation" };
  }

  await deps.forceNewDeployment(config.cluster, config.service);
  await deps.waitForStable(config.cluster, config.service);
  state = await currentState();
  if (!isFresh(state)) {
    throw new Error("ECS stable state does not contain fresh tasks for the new RDS secret.");
  }

  // Confirm real database access, not just a container/ALB health check.
  let lastError;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      await deps.checkPublicHealth(config.databaseHealthUrl);
      await deps.checkPublicHealth(config.publicSettingsUrl);
      return { outcome: "deployed", taskCount: state.tasks.length };
    } catch (error) {
      lastError = error;
      if (attempt < 3) await deps.sleep(10_000);
    }
  }
  throw lastError ?? new Error("Post-rotation public API health check failed.");
}

async function createAwsDependencies() {
  // The managed Node.js 22 Lambda runtime includes AWS SDK v3.
  const [
    {
      ECSClient,
      DescribeServicesCommand,
      ListTasksCommand,
      DescribeTasksCommand,
      UpdateServiceCommand,
      waitUntilServicesStable,
    },
    { SecretsManagerClient, DescribeSecretCommand },
  ] = await Promise.all([import("@aws-sdk/client-ecs"), import("@aws-sdk/client-secrets-manager")]);
  const ecs = new ECSClient({});
  const secrets = new SecretsManagerClient({});
  return {
    async describeSecret(SecretId) {
      return secrets.send(new DescribeSecretCommand({ SecretId }));
    },
    async describeService(cluster, serviceName) {
      const result = await ecs.send(
        new DescribeServicesCommand({ cluster, services: [serviceName] }),
      );
      if (result.failures?.length) throw new Error("ECS DescribeServices returned a failure.");
      return result.services?.[0];
    },
    async listTasks(cluster, serviceName) {
      const result = await ecs.send(
        new ListTasksCommand({ cluster, serviceName, desiredStatus: "RUNNING" }),
      );
      return result.taskArns ?? [];
    },
    async describeTasks(cluster, tasks) {
      const result = await ecs.send(new DescribeTasksCommand({ cluster, tasks }));
      if (result.failures?.length) throw new Error("ECS DescribeTasks returned a failure.");
      return result.tasks ?? [];
    },
    async forceNewDeployment(cluster, service) {
      await ecs.send(new UpdateServiceCommand({ cluster, service, forceNewDeployment: true }));
    },
    async waitForStable(cluster, serviceName) {
      const result = await waitUntilServicesStable(
        { client: ecs, maxWaitTime: 480, minDelay: 8, maxDelay: 20 },
        { cluster, services: [serviceName] },
      );
      if (result.state !== "SUCCESS") throw new Error("ECS deployment did not reach stable state.");
    },
    async checkPublicHealth(url) {
      const response = await fetch(url, { method: "GET", signal: AbortSignal.timeout(8000) });
      if (!response.ok) throw new Error(`Health check returned HTTP ${response.status}.`);
    },
    sleep,
  };
}

export async function handler(event) {
  const config = {
    accountId: process.env.EXPECTED_AWS_ACCOUNT,
    region: process.env.EXPECTED_AWS_REGION,
    secretArn: process.env.RDS_SECRET_ARN,
    cluster: process.env.ECS_CLUSTER_NAME,
    service: process.env.ECS_SERVICE_NAME,
    databaseHealthUrl: process.env.DATABASE_HEALTH_URL,
    publicSettingsUrl: process.env.PUBLIC_SETTINGS_URL,
  };
  if (Object.values(config).some((value) => typeof value !== "string" || !value)) {
    throw new Error("RDS rotation handler configuration is incomplete.");
  }
  const result = await handleRotation(event, await createAwsDependencies(), config);
  console.info(
    JSON.stringify({
      event: "rds-rotation-handler",
      outcome: result.outcome,
      reason: result.reason,
    }),
  );
  return result;
}
