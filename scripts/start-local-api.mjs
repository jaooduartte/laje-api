import "dotenv/config";

import { execFileSync, spawn } from "node:child_process";
import { createConnection, createServer } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import {
  renewManualOverride,
  startAwsInfrastructure,
  stopAwsInfrastructure,
} from "./aws-infrastructure.mjs";
import { runWithAwsInfrastructure } from "./aws-infrastructure-session.mjs";

const awsRegion = process.env.AWS_REGION || "sa-east-1";
const ecsContainer = process.env.AWS_ECS_CONTAINER || "api";
const databasePort = Number(process.env.AWS_RDS_PORT || "5432");
const localPort = Number(process.env.AWS_RDS_LOCAL_PORT || process.env.DATABASE_PORT || "15432");
const sessionManagerDocument = "AWS-StartPortForwardingSessionToRemoteHost";
const handledSignals = ["SIGINT", "SIGTERM", "SIGHUP"];

function requiredEnvironmentValue(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} precisa ser configurado no .env local.`);
  }
  return value;
}

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
  const ecsCluster = requiredEnvironmentValue("AWS_ECS_CLUSTER");
  const ecsService = requiredEnvironmentValue("AWS_ECS_SERVICE");
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
        `A porta local ${port} já está ocupada. Se o túnel SSM manual já está aberto, use-o. Para iniciar um túnel pelo npm run dev:aws, encerre o túnel manual com Ctrl+C primeiro.`,
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

async function waitForTunnel(tunnelProcess, spawnError, port) {
  const deadline = Date.now() + 30_000;

  while (Date.now() < deadline) {
    if (spawnError.error) {
      throw new Error(`Não foi possível iniciar o AWS CLI: ${spawnError.error.message}`);
    }
    if (tunnelProcess.exitCode !== null || tunnelProcess.signalCode !== null) {
      throw new Error("A sessão SSM encerrou antes de abrir o túnel do banco.");
    }
    if (await isPortReachable(port)) return;
    await delay(300);
  }

  throw new Error(`O túnel SSM não abriu a porta local ${port} em até 30 segundos.`);
}

async function terminateTunnelProcess(tunnelProcess, signal = "SIGTERM") {
  if (tunnelProcess.exitCode !== null || tunnelProcess.signalCode !== null) return;
  const exited = new Promise((resolve) => tunnelProcess.once("close", resolve));
  tunnelProcess.kill(signal);
  const stopped = await Promise.race([exited.then(() => true), delay(5_000).then(() => false)]);
  if (!stopped && tunnelProcess.exitCode === null && tunnelProcess.signalCode === null) {
    tunnelProcess.kill("SIGKILL");
    await exited;
  }
}

async function startTunnelSession(port, signalState, setTunnelProcess) {
  const databaseHost = requiredEnvironmentValue("AWS_RDS_HOST");
  const target = resolveRunningEcsExecTarget();
  if (signalState.signal) return { code: 0 };

  const parameters = JSON.stringify({
    host: [databaseHost],
    portNumber: [String(databasePort)],
    localPortNumber: [String(port)],
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
  setTunnelProcess(tunnelProcess);
  const spawnError = { error: null };
  const sessionResult = new Promise((resolve) => {
    tunnelProcess.once("error", (error) => {
      spawnError.error = error;
      resolve({ error });
    });
    tunnelProcess.once("exit", (code, signal) => resolve({ code: code ?? 0, signal }));
  });

  try {
    await waitForTunnel(tunnelProcess, spawnError, port);
  } catch (error) {
    if (tunnelProcess.exitCode === null && tunnelProcess.signalCode === null) {
      await terminateTunnelProcess(tunnelProcess);
    }
    if (signalState.signal) return { code: 0 };
    throw error;
  }

  if (signalState.signal) {
    await terminateTunnelProcess(tunnelProcess, signalState.signal);
    return { code: 0 };
  }

  console.log(`Túnel SSM conectado em 127.0.0.1:${port}. Pressione Ctrl+C para encerrá-lo.`);
  const result = await sessionResult;
  if (result.error) {
    throw new Error(`A sessão SSM falhou: ${result.error.message}`, { cause: result.error });
  }
  if (result.signal) {
    console.log(`Sessão SSM encerrada (${result.signal}).`);
  }
  return { code: result.code };
}

async function main() {
  const signalState = { signal: null };
  let tunnelProcess = null;
  const signalHandlers = new Map(
    handledSignals.map((signal) => [
      signal,
      () => {
        signalState.signal = signal;
        if (tunnelProcess && tunnelProcess.exitCode === null && tunnelProcess.signalCode === null) {
          tunnelProcess.kill(signal);
        }
      },
    ]),
  );
  for (const [signal, handler] of signalHandlers) {
    process.once(signal, handler);
  }

  try {
    requiredEnvironmentValue("AWS_RDS_HOST");
    requiredEnvironmentValue("AWS_ECS_CLUSTER");
    requiredEnvironmentValue("AWS_ECS_SERVICE");
    if (!Number.isInteger(databasePort) || databasePort < 1 || databasePort > 65_535) {
      throw new Error("AWS_RDS_PORT precisa ser uma porta válida.");
    }
    if (!Number.isInteger(localPort) || localPort < 1 || localPort > 65_535) {
      throw new Error("AWS_RDS_LOCAL_PORT precisa ser uma porta válida.");
    }
    if (signalState.signal) return;
    await assertLocalPortIsFree(localPort);
    const result = await runWithAwsInfrastructure(
      startAwsInfrastructure,
      async (resourcesStartedBySession) => {
        const overrideHolder = resourcesStartedBySession.manualOverride?.holder;
        const overrideRenewalTimer = overrideHolder
          ? setInterval(
              () => {
                void renewManualOverride(overrideHolder).catch((error) => {
                  console.error("Não foi possível renovar o override manual do túnel AWS.", error);
                });
              },
              4 * 60 * 60 * 1_000,
            )
          : null;
        overrideRenewalTimer?.unref();

        try {
          if (signalState.signal) return { code: 0 };
          await assertLocalPortIsFree(localPort);
          if (signalState.signal) return { code: 0 };
          return startTunnelSession(localPort, signalState, (process) => {
            tunnelProcess = process;
          });
        } finally {
          if (overrideRenewalTimer) clearInterval(overrideRenewalTimer);
        }
      },
      stopAwsInfrastructure,
    );
    process.exitCode = result.code;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    for (const [signal, handler] of signalHandlers) {
      process.removeListener(signal, handler);
    }
    if (tunnelProcess) {
      await terminateTunnelProcess(tunnelProcess).catch((error) => {
        console.error(error.message);
        process.exitCode = 1;
      });
    }
  }
}

main();
