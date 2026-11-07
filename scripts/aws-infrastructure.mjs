import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const awsRegion = process.env.AWS_REGION || "sa-east-1";
const rdsStoppedPollIntervalMs = 15_000;
const rdsStoppedTimeoutMs = 30 * 60 * 1_000;

function requiredEnvironmentValue(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} precisa ser configurado no .env local.`);
  }
  return value;
}

async function runAws(argumentsList, description, outputJson = false) {
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

async function setEcsDesiredCount(desiredCount) {
  const service = await getEcsService();
  await updateEcsDesiredCount(desiredCount, service);
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

export async function startAwsInfrastructure() {
  const resourcesStartedBySession = { ecs: false, rds: false };
  try {
    await assertExpectedAwsAccount();
    await startRds(resourcesStartedBySession);
    await startEcs(resourcesStartedBySession);
    console.log("RDS e ECS estão disponíveis para o desenvolvimento local.");
    return resourcesStartedBySession;
  } catch (error) {
    if (!resourcesStartedBySession.rds && !resourcesStartedBySession.ecs) {
      throw error;
    }
    try {
      await stopAwsInfrastructure(resourcesStartedBySession);
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

export async function stopAwsInfrastructure(resourcesStartedBySession) {
  const stopAll = resourcesStartedBySession === undefined;
  const shouldStopEcs = stopAll || resourcesStartedBySession.ecs;
  const shouldStopRds = stopAll || resourcesStartedBySession.rds;
  if (!shouldStopEcs && !shouldStopRds) return;

  await assertExpectedAwsAccount();
  const cleanupErrors = [];
  if (shouldStopEcs) {
    try {
      await setEcsDesiredCount(0);
    } catch (error) {
      cleanupErrors.push(error);
    }
  }
  if (shouldStopRds) {
    try {
      await stopRds();
    } catch (error) {
      cleanupErrors.push(error);
    }
  }
  if (cleanupErrors.length > 0) {
    throw new AggregateError(cleanupErrors, "Falha ao desligar os recursos AWS da sessão.");
  }
  console.log(
    stopAll
      ? "ECS e RDS foram parados."
      : "Os recursos AWS iniciados por esta sessão foram parados.",
  );
}
