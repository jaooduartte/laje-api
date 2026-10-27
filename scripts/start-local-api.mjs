import "dotenv/config";

import { execFileSync, spawn } from "node:child_process";
import { createConnection, createServer } from "node:net";
import { setTimeout as delay } from "node:timers/promises";

const awsRegion = process.env.AWS_REGION || "sa-east-1";
const ecsCluster = process.env.AWS_ECS_CLUSTER || "laje-staging-api";
const ecsService = process.env.AWS_ECS_SERVICE || "laje-staging-api";
const ecsContainer = process.env.AWS_ECS_CONTAINER || "api";
const databaseHost =
  process.env.AWS_RDS_HOST || "laje-staging-postgres.c7s8g84qonz5.sa-east-1.rds.amazonaws.com";
const databasePort = Number(process.env.AWS_RDS_PORT || "5432");
const localPort = Number(process.env.AWS_RDS_LOCAL_PORT || process.env.DATABASE_PORT || "15432");
const sessionManagerDocument = "AWS-StartPortForwardingSessionToRemoteHost";

function runAwsJson(argumentsList, description) {
  try {
    const output = execFileSync(
      "aws",
      [...argumentsList, "--region", awsRegion, "--no-cli-pager", "--output", "json"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    return JSON.parse(output);
  } catch (error) {
    const details = error.stderr?.toString().trim() || error.message;
    throw new Error(`AWS CLI falhou ao ${description}.\n${details}`, { cause: error });
  }
}

function resolveRunningEcsExecTarget() {
  const taskList = runAwsJson(
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
    "localizar a tarefa ECS ativa",
  );
  const taskArns = taskList.taskArns || [];

  if (taskArns.length === 0) {
    throw new Error(`Nenhuma tarefa ativa foi encontrada no serviço ECS ${ecsService}.`);
  }

  const taskDetails = runAwsJson(
    ["ecs", "describe-tasks", "--cluster", ecsCluster, "--tasks", ...taskArns],
    "consultar a tarefa ECS ativa",
  );
  const task = (taskDetails.tasks || []).find((candidate) => {
    const container = (candidate.containers || []).find((item) => item.name === ecsContainer);
    return candidate.lastStatus === "RUNNING" && container?.runtimeId;
  });

  if (!task) {
    throw new Error(
      `Não encontrei o container ${ecsContainer} em uma tarefa ECS em execução. Confira o nome do container e se o ECS Exec está habilitado.`,
    );
  }

  const container = task.containers.find((item) => item.name === ecsContainer);
  const taskId = task.taskArn.split("/").at(-1);

  return `ecs:${ecsCluster}_${taskId}_${container.runtimeId}`;
}

async function assertLocalPortIsFree(port) {
  try {
    await new Promise((resolve, reject) => {
      const server = createServer();
      server.once("error", reject);
      server.listen(port, "127.0.0.1", () => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    });
  } catch (error) {
    if (error.code === "EADDRINUSE") {
      throw new Error(
        `A porta local ${port} já está ocupada. Se o túnel SSM manual já está aberto, use-o. Para iniciar um túnel pelo npm start, encerre o túnel manual com Ctrl+C primeiro.`,
        { cause: error },
      );
    }
    throw error;
  }
}

function isPortReachable(port) {
  return new Promise((resolve) => {
    const connection = createConnection({ host: "127.0.0.1", port });
    connection.setTimeout(500);
    connection.once("connect", () => {
      connection.destroy();
      resolve(true);
    });
    connection.once("error", () => resolve(false));
    connection.once("timeout", () => {
      connection.destroy();
      resolve(false);
    });
  });
}

async function waitForTunnel(tunnelProcess, spawnError) {
  const deadline = Date.now() + 30_000;

  while (Date.now() < deadline) {
    if (spawnError.error) {
      throw new Error(`Não foi possível iniciar o AWS CLI: ${spawnError.error.message}`);
    }
    if (tunnelProcess.exitCode !== null || tunnelProcess.signalCode !== null) {
      throw new Error("A sessão SSM encerrou antes de abrir o túnel do banco.");
    }
    if (await isPortReachable(localPort)) return;
    await delay(300);
  }

  throw new Error(`O túnel SSM não abriu a porta local ${localPort} em até 30 segundos.`);
}

async function startTunnel() {
  if (!Number.isInteger(databasePort) || databasePort < 1 || databasePort > 65_535) {
    throw new Error("AWS_RDS_PORT precisa ser uma porta válida.");
  }
  if (!Number.isInteger(localPort) || localPort < 1 || localPort > 65_535) {
    throw new Error("AWS_RDS_LOCAL_PORT precisa ser uma porta válida.");
  }

  await assertLocalPortIsFree(localPort);
  const target = resolveRunningEcsExecTarget();
  const parameters = JSON.stringify({
    host: [databaseHost],
    portNumber: [String(databasePort)],
    localPortNumber: [String(localPort)],
  });
  const tunnelProcess = spawn(
    "aws",
    [
      "ssm",
      "start-session",
      "--target",
      target,
      "--document-name",
      sessionManagerDocument,
      "--parameters",
      parameters,
      "--region",
      awsRegion,
    ],
    { stdio: "inherit" },
  );
  const spawnError = { error: null };
  tunnelProcess.once("error", (error) => {
    spawnError.error = error;
  });

  try {
    await waitForTunnel(tunnelProcess, spawnError);
  } catch (error) {
    if (tunnelProcess.exitCode === null && tunnelProcess.signalCode === null) {
      tunnelProcess.kill("SIGTERM");
    }
    throw error;
  }

  console.log(`Túnel SSM conectado em 127.0.0.1:${localPort}. Pressione Ctrl+C para encerrá-lo.`);

  return new Promise((resolve, reject) => {
    const stopTunnel = (signal) => {
      if (tunnelProcess.exitCode === null && tunnelProcess.signalCode === null) {
        tunnelProcess.kill(signal);
      }
    };
    const handleSigint = () => stopTunnel("SIGINT");
    const handleSigterm = () => stopTunnel("SIGTERM");

    process.once("SIGINT", handleSigint);
    process.once("SIGTERM", handleSigterm);

    tunnelProcess.once("error", reject);
    tunnelProcess.once("exit", (code, signal) => {
      process.removeListener("SIGINT", handleSigint);
      process.removeListener("SIGTERM", handleSigterm);
      if (signal) {
        console.log(`Sessão SSM encerrada (${signal}).`);
      }
      resolve(code ?? 0);
    });
  });
}

async function main() {
  process.exitCode = await startTunnel();
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
