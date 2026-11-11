import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import { assertAwsOperationLockHealthy, withAwsOperationLock } from "./aws-operation-lock.mjs";

const execFileAsync = promisify(execFile);
const awsRegion = process.env.AWS_REGION || "sa-east-1";
const rdsStoppedPollIntervalMs = 15_000;
const rdsStoppedTimeoutMs = 30 * 60 * 1_000;
const ecsTaskShutdownPollIntervalMs = 15_000;
const ecsTaskShutdownMaxRetries = 12;

function requiredEnvironmentValue(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} precisa ser configurado no .env local.`);
  }
  return value;
}

async function runAws(argumentsList, description, outputJson = false) {
  assertAwsOperationLockHealthy();
  const options = ["--region", awsRegion, "--no-cli-pager"];
  if (outputJson) options.push("--output", "json");

  try {
    const { stdout } = await execFileAsync("aws", [...argumentsList, ...options], {
      encoding: "utf8",
    });
    return outputJson ? JSON.parse(stdout) : stdout;
  } catch (error) {
    const details = error.stderr?.toString().trim() || error.message;
    throw new Error("AWS CLI falhou ao " + description + ".\n" + details, { cause: error });
  }
}

async function getManualOverride(tableName) {
  if (!tableName) return null;
  const response = await runAws(
    [
      "dynamodb",
      "get-item",
      "--table-name",
      tableName,
      "--key",
      JSON.stringify({ LockId: { S: "manual-override" } }),
      "--consistent-read",
    ],
    "consultar o override manual de operação",
    true,
  );
  const item = response.Item;
  if (Number(item?.ExpiresAt?.N ?? 0) <= Math.floor(Date.now() / 1_000)) return null;
  return item ?? null;
}

async function setManualOverride(tableName, holder, previousOverride) {
  if (!tableName) return { tableName: null, holder, previousOverride };
  const expiresAt = Math.floor(Date.now() / 1_000) + 12 * 60 * 60;
  await runAws(
    [
      "dynamodb",
      "put-item",
      "--table-name",
      tableName,
      "--item",
      JSON.stringify({
        LockId: { S: "manual-override" },
        Holder: { S: holder },
        ExpiresAt: { N: String(expiresAt) },
      }),
    ],
    "ativar o override manual por 12 horas",
  );
  return { tableName, holder, previousOverride };
}

async function restoreManualOverride(override) {
  if (!override?.tableName || !override.holder) return;
  const current = await getManualOverride(override.tableName);
  if (current?.Holder?.S !== override.holder) return;

  const previousExpiresAt = Number(override.previousOverride?.ExpiresAt?.N ?? 0);
  if (override.previousOverride && previousExpiresAt > Math.floor(Date.now() / 1_000)) {
    await runAws(
      [
        "dynamodb",
        "put-item",
        "--table-name",
        override.tableName,
        "--item",
        JSON.stringify(override.previousOverride),
        "--condition-expression",
        "Holder = :holder",
        "--expression-attribute-values",
        JSON.stringify({ ":holder": { S: override.holder } }),
      ],
      "restaurar o override manual anterior",
    );
    return;
  }

  await runAws(
    [
      "dynamodb",
      "delete-item",
      "--table-name",
      override.tableName,
      "--key",
      JSON.stringify({ LockId: { S: "manual-override" } }),
      "--condition-expression",
      "Holder = :holder",
      "--expression-attribute-values",
      JSON.stringify({ ":holder": { S: override.holder } }),
    ],
    "remover o override manual da sessão local",
  );
}

async function clearManualOverride(tableName) {
  if (!tableName) return;
  await runAws(
    [
      "dynamodb",
      "delete-item",
      "--table-name",
      tableName,
      "--key",
      JSON.stringify({ LockId: { S: "manual-override" } }),
    ],
    "remover o override manual",
  );
}

export async function renewManualOverride(holder) {
  await withAwsOperationLock(async (lock) => {
    if (!lock) return;
    const tableName = lock.tableName;
    const now = Math.floor(Date.now() / 1_000);
    await runAws(
      [
        "dynamodb",
        "update-item",
        "--table-name",
        tableName,
        "--key",
        JSON.stringify({ LockId: { S: "manual-override" } }),
        "--update-expression",
        "SET ExpiresAt = :expiresAt",
        "--condition-expression",
        "Holder = :holder AND ExpiresAt >= :now",
        "--expression-attribute-values",
        JSON.stringify({
          ":holder": { S: holder },
          ":now": { N: String(now) },
          ":expiresAt": { N: String(now + 12 * 60 * 60) },
        }),
      ],
      "renovar o override manual da sessão local",
    );
  });
}

async function requestBracketPreviewWorkerDrain(tableName, operationId) {
  if (!tableName)
    throw new Error("A tabela de lock da rotação é necessária para drenar o worker SQS.");
  const now = Math.floor(Date.now() / 1_000);
  await runAws(
    [
      "dynamodb",
      "put-item",
      "--table-name",
      tableName,
      "--item",
      JSON.stringify({
        LockId: { S: "bracket-preview-worker" },
        State: { S: "DRAINING" },
        OperationId: { S: operationId },
        RequestedAt: { N: String(now) },
        ExpiresAt: { N: String(now + 1_200) },
      }),
    ],
    "solicitar drenagem do worker SQS",
  );
}

async function getBracketPreviewWorkerDrain(tableName, operationId) {
  const response = await runAws(
    [
      "dynamodb",
      "get-item",
      "--table-name",
      tableName,
      "--key",
      JSON.stringify({ LockId: { S: "bracket-preview-worker" } }),
      "--consistent-read",
    ],
    "consultar drenagem do worker SQS",
    true,
  );
  const item = response.Item;
  if (item?.OperationId?.S !== operationId) return { state: "MISSING", timedOut: true };
  const requestedAt = Number(item.RequestedAt?.N ?? 0);
  return {
    state: item.State?.S ?? "MISSING",
    timedOut: Math.floor(Date.now() / 1_000) - requestedAt >= 600,
  };
}

async function clearBracketPreviewWorkerDrain(tableName, operationId) {
  if (!tableName) return;
  try {
    await runAws(
      [
        "dynamodb",
        "delete-item",
        "--table-name",
        tableName,
        "--key",
        JSON.stringify({ LockId: { S: "bracket-preview-worker" } }),
        "--condition-expression",
        "OperationId = :operationId",
        "--expression-attribute-values",
        JSON.stringify({ ":operationId": { S: operationId } }),
      ],
      "limpar o estado de drenagem do worker SQS",
    );
  } catch (error) {
    if (!error.message.includes("ConditionalCheckFailedException")) throw error;
  }
}

async function waitForBracketPreviewWorkerDrain(tableName, operationId) {
  const deadline = Date.now() + 10 * 60 * 1_000;
  while (Date.now() < deadline) {
    const state = await getBracketPreviewWorkerDrain(tableName, operationId);
    if (state.state === "DRAINED") return;
    if (state.timedOut) break;
    await new Promise((resolve) => setTimeout(resolve, 15_000));
  }
  await clearBracketPreviewWorkerDrain(tableName, operationId);
  throw new Error("O worker SQS não confirmou a drenagem; ECS e RDS permaneceram ligados.");
}

async function listRunningEcsTasks() {
  const ecsCluster = requiredEnvironmentValue("AWS_ECS_CLUSTER");
  const ecsService = requiredEnvironmentValue("AWS_ECS_SERVICE");
  const response = await runAws(
    [
      "ecs",
      "list-tasks",
      "--cluster",
      ecsCluster,
      "--service-name",
      ecsService,
      "--desired-status",
      "RUNNING",
    ],
    "localizar tasks ECS para desligamento",
    true,
  );
  return response.taskArns ?? [];
}

async function verifyGracefulEcsShutdown(taskArns) {
  if (taskArns.length === 0) return;
  const ecsCluster = requiredEnvironmentValue("AWS_ECS_CLUSTER");
  let retries = 0;

  while (true) {
    const response = await runAws(
      ["ecs", "describe-tasks", "--cluster", ecsCluster, "--tasks", ...taskArns],
      "validar o encerramento gracioso das tasks ECS",
      true,
    );
    if (response.failures?.length || response.tasks?.length !== taskArns.length) {
      throw new Error("Não foi possível confirmar o encerramento de todas as tasks ECS.");
    }

    const taskWithFailedContainer = response.tasks.find(
      (task) =>
        task.lastStatus === "STOPPED" &&
        task.containers?.some((container) => container.exitCode !== 0),
    );
    if (taskWithFailedContainer) {
      throw new Error(
        `A task ECS ${taskWithFailedContainer.taskArn ?? "desconhecida"} não encerrou de forma graciosa; o RDS será mantido ligado.`,
      );
    }

    const taskStillStopping = response.tasks.find((task) => task.lastStatus !== "STOPPED");
    if (!taskStillStopping) return;
    if (retries >= ecsTaskShutdownMaxRetries) {
      throw new Error(
        `A task ECS ${taskStillStopping.taskArn ?? "desconhecida"} não encerrou após ${ecsTaskShutdownMaxRetries} tentativas; o RDS será mantido ligado.`,
      );
    }

    console.log(
      `Aguardando a task ECS ${taskStillStopping.taskArn ?? "desconhecida"} encerrar (${retries + 1}/${ecsTaskShutdownMaxRetries})...`,
    );
    retries += 1;
    await new Promise((resolve) => setTimeout(resolve, ecsTaskShutdownPollIntervalMs));
  }
}

async function assertExpectedAwsAccount() {
  const expectedAccountId = requiredEnvironmentValue("AWS_EXPECTED_ACCOUNT_ID");
  if (!/^\d{12}$/.test(expectedAccountId)) {
    throw new Error("AWS_EXPECTED_ACCOUNT_ID precisa conter um ID de conta AWS com 12 dígitos.");
  }

  const identity = await runAws(
    ["sts", "get-caller-identity"],
    "validar a identidade AWS atual",
    true,
  );

  if (identity.Account !== expectedAccountId) {
    throw new Error(
      "A conta AWS ativa (" +
        identity.Account +
        ") não corresponde à conta configurada (" +
        expectedAccountId +
        "). Nenhum recurso foi alterado.",
    );
  }
}

async function getRdsStatus() {
  const rdsInstanceIdentifier = requiredEnvironmentValue("AWS_RDS_INSTANCE_IDENTIFIER");
  const response = await runAws(
    ["rds", "describe-db-instances", "--db-instance-identifier", rdsInstanceIdentifier],
    "consultar a instância RDS " + rdsInstanceIdentifier,
    true,
  );
  const instance = response.DBInstances?.[0];

  if (!instance) {
    throw new Error("A instância RDS " + rdsInstanceIdentifier + " não foi encontrada.");
  }

  return instance.DBInstanceStatus;
}

async function waitForRds(status) {
  const rdsInstanceIdentifier = requiredEnvironmentValue("AWS_RDS_INSTANCE_IDENTIFIER");
  console.log("Aguardando o RDS " + rdsInstanceIdentifier + " ficar " + status + "...");

  if (status === "stopped") {
    const deadline = Date.now() + rdsStoppedTimeoutMs;
    let currentStatus = await getRdsStatus();

    while (currentStatus !== status && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, rdsStoppedPollIntervalMs));
      currentStatus = await getRdsStatus();
    }

    if (currentStatus !== status) {
      throw new Error(
        "Tempo limite excedido ao aguardar o RDS " +
          rdsInstanceIdentifier +
          " ficar stopped. Estado atual: " +
          currentStatus +
          ".",
      );
    }

    return;
  }

  await runAws(
    ["rds", "wait", "db-instance-" + status, "--db-instance-identifier", rdsInstanceIdentifier],
    "aguardar o RDS ficar " + status,
  );
}

async function startRds(resourcesStartedBySession) {
  let status = await getRdsStatus();

  if (status === "available") {
    console.log("RDS já está disponível.");
    return;
  }

  if (status === "stopping") {
    await waitForRds("stopped");
    status = "stopped";
  }

  if (status === "stopped") {
    resourcesStartedBySession.rds = true;
    const rdsInstanceIdentifier = requiredEnvironmentValue("AWS_RDS_INSTANCE_IDENTIFIER");
    console.log("Iniciando o RDS...");
    await runAws(
      ["rds", "start-db-instance", "--db-instance-identifier", rdsInstanceIdentifier],
      "iniciar o RDS",
      true,
    );
  } else if (status !== "starting") {
    console.log("RDS está em estado " + status + "; aguardando disponibilidade.");
  }

  await waitForRds("available");
}

async function stopRds() {
  const rdsInstanceIdentifier = requiredEnvironmentValue("AWS_RDS_INSTANCE_IDENTIFIER");
  let status = await getRdsStatus();

  if (status === "stopped") {
    console.log("RDS já está parado.");
    return;
  }

  if (status === "stopping") {
    await waitForRds("stopped");
    return;
  }

  if (status !== "available" && status !== "starting") {
    console.log("RDS está em estado " + status + "; aguardando disponibilidade.");
    await waitForRds("available");
    status = "available";
  }

  if (status === "starting") {
    await waitForRds("available");
  }

  console.log("Parando o RDS...");
  await runAws(
    ["rds", "stop-db-instance", "--db-instance-identifier", rdsInstanceIdentifier],
    "parar o RDS",
    true,
  );
  await waitForRds("stopped");
}

async function getEcsService() {
  const ecsCluster = requiredEnvironmentValue("AWS_ECS_CLUSTER");
  const ecsService = requiredEnvironmentValue("AWS_ECS_SERVICE");
  const response = await runAws(
    ["ecs", "describe-services", "--cluster", ecsCluster, "--services", ecsService],
    "consultar o serviço ECS " + ecsService,
    true,
  );
  const service = response.services?.[0];

  if (response.failures?.length || !service) {
    throw new Error(
      "O serviço ECS " +
        ecsService +
        " não foi encontrado no cluster " +
        ecsCluster +
        ". " +
        JSON.stringify(response.failures || []),
    );
  }

  if (service.status !== "ACTIVE") {
    throw new Error("O serviço ECS " + ecsService + " está no estado " + service.status + ".");
  }

  return service;
}

async function waitForEcsServiceToStabilize() {
  const ecsCluster = requiredEnvironmentValue("AWS_ECS_CLUSTER");
  const ecsService = requiredEnvironmentValue("AWS_ECS_SERVICE");
  console.log("Aguardando o serviço ECS estabilizar...");
  await runAws(
    ["ecs", "wait", "services-stable", "--cluster", ecsCluster, "--services", ecsService],
    "aguardar a estabilização do serviço ECS",
  );
}

async function updateEcsDesiredCount(desiredCount, service) {
  const ecsCluster = requiredEnvironmentValue("AWS_ECS_CLUSTER");
  const ecsService = requiredEnvironmentValue("AWS_ECS_SERVICE");

  if (service.desiredCount !== desiredCount) {
    console.log(
      (desiredCount === 0 ? "Parando" : "Iniciando") + " o serviço ECS " + ecsService + "...",
    );
    await runAws(
      [
        "ecs",
        "update-service",
        "--cluster",
        ecsCluster,
        "--service",
        ecsService,
        "--desired-count",
        String(desiredCount),
      ],
      "alterar a quantidade desejada do serviço ECS",
      true,
    );
  } else {
    console.log("Serviço ECS já está configurado com desired count " + String(desiredCount) + ".");
  }

  await waitForEcsServiceToStabilize();
}

async function startEcs(resourcesStartedBySession) {
  const service = await getEcsService();
  if (service.desiredCount === 0) {
    resourcesStartedBySession.ecs = true;
    await updateEcsDesiredCount(1, service);
    return;
  }

  console.log(
    `Serviço ECS já tinha desired count ${String(service.desiredCount)}; mantendo o estado existente.`,
  );
  await waitForEcsServiceToStabilize();
}

async function clearAnyBracketPreviewWorkerDrain(tableName) {
  if (!tableName) return;
  await runAws(
    [
      "dynamodb",
      "delete-item",
      "--table-name",
      tableName,
      "--key",
      JSON.stringify({ LockId: { S: "bracket-preview-worker" } }),
    ],
    "remover sinalização antiga de drenagem do worker SQS",
  );
}

async function startAwsInfrastructureUnlocked(lock) {
  const resourcesStartedBySession = { ecs: false, rds: false, manualOverride: null };
  const tableName = lock?.tableName ?? null;
  const manualOverrideHolder = randomUUID();
  const previousOverride = await getManualOverride(tableName);
  resourcesStartedBySession.manualOverride = await setManualOverride(
    tableName,
    manualOverrideHolder,
    previousOverride,
  );

  try {
    await clearAnyBracketPreviewWorkerDrain(tableName);
    await startRds(resourcesStartedBySession);
    await startEcs(resourcesStartedBySession);
    console.log("RDS e ECS estão disponíveis para o desenvolvimento local.");
    return resourcesStartedBySession;
  } catch (error) {
    try {
      await stopAwsInfrastructureUnlocked(resourcesStartedBySession, lock);
      await restoreManualOverride(resourcesStartedBySession.manualOverride);
    } catch (cleanupError) {
      throw new AggregateError(
        [error, cleanupError],
        "Falha ao iniciar a infraestrutura AWS e ao limpar os recursos iniciados pela sessão.",
        { cause: cleanupError },
      );
    }
    throw error;
  }
}

async function stopAwsInfrastructureUnlocked(resourcesStartedBySession, lock) {
  const stopAll = resourcesStartedBySession === undefined;
  const shouldStopEcs = stopAll || resourcesStartedBySession.ecs;
  const shouldStopRds = stopAll || resourcesStartedBySession.rds;
  const tableName = lock?.tableName ?? resourcesStartedBySession?.manualOverride?.tableName ?? null;

  if (stopAll) await clearManualOverride(tableName);

  let service = null;
  if (shouldStopEcs) {
    service = await getEcsService();
    const runningTaskArns = await listRunningEcsTasks();
    if (runningTaskArns.length > 0) {
      const operationId = randomUUID();
      await requestBracketPreviewWorkerDrain(tableName, operationId);
      await waitForBracketPreviewWorkerDrain(tableName, operationId);
    }

    await updateEcsDesiredCount(0, service);
    await verifyGracefulEcsShutdown(runningTaskArns);
  }

  if (shouldStopRds) {
    if (!service) {
      try {
        service = await getEcsService();
      } catch (error) {
        if (!error.message.includes("não foi encontrado")) throw error;
        service = { desiredCount: 0, runningCount: 0 };
      }
    }
    if (!shouldStopEcs && (service.desiredCount > 0 || service.runningCount > 0)) {
      console.log("ECS continua ativo; mantendo o RDS para preservar o serviço existente.");
    } else {
      await stopRds();
    }
  }

  if (!stopAll) await restoreManualOverride(resourcesStartedBySession.manualOverride);

  console.log(
    stopAll
      ? "ECS e RDS foram parados."
      : "Os recursos AWS iniciados por esta sessão foram parados.",
  );
}

export async function startAwsInfrastructure() {
  await assertExpectedAwsAccount();
  requiredEnvironmentValue("AWS_ECS_CLUSTER");
  requiredEnvironmentValue("AWS_ECS_SERVICE");
  requiredEnvironmentValue("AWS_RDS_INSTANCE_IDENTIFIER");

  return withAwsOperationLock((lock) => startAwsInfrastructureUnlocked(lock));
}

export async function stopAwsInfrastructure(resourcesStartedBySession) {
  await assertExpectedAwsAccount();
  requiredEnvironmentValue("AWS_ECS_CLUSTER");
  requiredEnvironmentValue("AWS_ECS_SERVICE");
  requiredEnvironmentValue("AWS_RDS_INSTANCE_IDENTIFIER");

  return withAwsOperationLock((lock) =>
    stopAwsInfrastructureUnlocked(resourcesStartedBySession, lock),
  );
}
