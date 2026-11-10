import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";

const execFileAsync = promisify(execFile);
const awsRegion = process.env.AWS_REGION || "sa-east-1";
const lockTtlSeconds = 900;
const lockRenewIntervalMs = 5 * 60 * 1_000;
let activeLockError = null;

function lockId() {
  const serviceName = process.env.AWS_ECS_SERVICE?.trim();
  if (!serviceName)
    throw new Error("AWS_ECS_SERVICE precisa ser configurado para usar o lock AWS.");
  return serviceName;
}

async function runAws(argumentsList, outputJson = false) {
  try {
    const { stdout } = await execFileAsync(
      "aws",
      [
        ...argumentsList,
        "--region",
        awsRegion,
        "--no-cli-pager",
        ...(outputJson ? ["--output", "json"] : []),
      ],
      { encoding: "utf8" },
    );
    return outputJson ? JSON.parse(stdout) : stdout;
  } catch (error) {
    const details = error.stderr?.toString().trim() || error.message;
    throw new Error("AWS CLI failed to manage the staging operation lock.\n" + details, {
      cause: error,
    });
  }
}

function isLockConflict(error) {
  return error.cause?.stderr?.toString().includes("ConditionalCheckFailedException") ?? false;
}

export async function resolveAwsOperationLockTable() {
  const configured = process.env.AWS_OPERATION_LOCK_TABLE?.trim();
  if (configured) return configured;

  const serviceName = lockId();
  if (!serviceName.endsWith("-api")) {
    throw new Error("Set AWS_OPERATION_LOCK_TABLE when AWS_ECS_SERVICE does not end in -api.");
  }
  const tableName = `${serviceName.slice(0, -4)}-rds-rotation-lock`;

  try {
    await runAws(["dynamodb", "describe-table", "--table-name", tableName], true);
    return tableName;
  } catch (error) {
    if (error.cause?.stderr?.toString().includes("ResourceNotFoundException")) return null;
    throw error;
  }
}

export async function acquireAwsOperationLock(
  tableName,
  holder,
  ttlSeconds = lockTtlSeconds,
  waitTimeoutMs = 0,
) {
  if (!tableName) return null;

  const deadline = Date.now() + waitTimeoutMs;
  while (true) {
    const now = Math.floor(Date.now() / 1_000);
    const item = {
      LockId: { S: lockId() },
      Holder: { S: holder },
      ExpiresAt: { N: String(now + ttlSeconds) },
    };

    try {
      await runAws([
        "dynamodb",
        "put-item",
        "--table-name",
        tableName,
        "--item",
        JSON.stringify(item),
        "--condition-expression",
        "attribute_not_exists(LockId) OR ExpiresAt < :now",
        "--expression-attribute-values",
        JSON.stringify({ ":now": { N: String(now) } }),
      ]);
      return { tableName, holder };
    } catch (error) {
      if (!isLockConflict(error) || Date.now() >= deadline) throw error;
      await delay(Math.min(15_000, Math.max(1, deadline - Date.now())));
    }
  }
}

export async function renewAwsOperationLock(lock, ttlSeconds = lockTtlSeconds) {
  if (!lock) return;
  const now = Math.floor(Date.now() / 1_000);
  await runAws([
    "dynamodb",
    "update-item",
    "--table-name",
    lock.tableName,
    "--key",
    JSON.stringify({ LockId: { S: lockId() } }),
    "--update-expression",
    "SET ExpiresAt = :expiresAt",
    "--condition-expression",
    "Holder = :holder AND ExpiresAt >= :now",
    "--expression-attribute-values",
    JSON.stringify({
      ":holder": { S: lock.holder },
      ":now": { N: String(now) },
      ":expiresAt": { N: String(now + ttlSeconds) },
    }),
  ]);
}

export async function releaseAwsOperationLock(lock) {
  if (!lock) return;
  try {
    await runAws([
      "dynamodb",
      "delete-item",
      "--table-name",
      lock.tableName,
      "--key",
      JSON.stringify({ LockId: { S: lockId() } }),
      "--condition-expression",
      "Holder = :holder",
      "--expression-attribute-values",
      JSON.stringify({ ":holder": { S: lock.holder } }),
    ]);
  } catch (error) {
    const details = error.cause?.stderr?.toString() ?? "";
    if (
      !details.includes("ConditionalCheckFailedException") &&
      !details.includes("ResourceNotFoundException")
    ) {
      throw error;
    }
  }
}

export async function withAwsOperationLock(run) {
  const tableName = await resolveAwsOperationLockTable();
  if (!tableName) {
    console.warn("No staging operation lock table is provisioned in this region.");
    return run(null);
  }

  const lock = await acquireAwsOperationLock(
    tableName,
    randomUUID(),
    lockTtlSeconds,
    10 * 60 * 1_000,
  );
  if (!lock) return run(null);

  activeLockError = null;
  const renewTimer = setInterval(() => {
    void renewAwsOperationLock(lock).catch((error) => {
      activeLockError = error;
    });
  }, lockRenewIntervalMs);
  renewTimer.unref();

  try {
    return await run(lock);
  } finally {
    clearInterval(renewTimer);
    await releaseAwsOperationLock(lock);
    activeLockError = null;
  }
}

export function assertAwsOperationLockHealthy() {
  if (activeLockError) {
    throw new Error("The staging operation lock could not be renewed.", { cause: activeLockError });
  }
}

if (process.argv[1]?.endsWith("aws-operation-lock.mjs")) {
  const [command, holder] = process.argv.slice(2);
  if (command === "acquire") {
    const tableName = await resolveAwsOperationLockTable();
    const lock = await acquireAwsOperationLock(
      tableName,
      holder || randomUUID(),
      3_600,
      10 * 60 * 1_000,
    );
    if (lock) console.log(JSON.stringify(lock));
  } else if (command === "release") {
    const tableName = await resolveAwsOperationLockTable();
    if (tableName && holder) await releaseAwsOperationLock({ tableName, holder });
  } else {
    console.error("Use: node scripts/aws-operation-lock.mjs <acquire|release> [holder].");
    process.exitCode = 1;
  }
}
