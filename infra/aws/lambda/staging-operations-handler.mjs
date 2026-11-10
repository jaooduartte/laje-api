let dependenciesPromise;

async function loadDependencies() {
  if (!dependenciesPromise) {
    dependenciesPromise = Promise.all([
      import("@aws-sdk/client-dynamodb"),
      import("@aws-sdk/client-ecs"),
      import("@aws-sdk/client-rds"),
    ]).then(([dynamodbModule, ecsModule, rdsModule]) => {
      const dynamodb = new dynamodbModule.DynamoDBClient({});
      const ecs = new ecsModule.ECSClient({});
      const rds = new rdsModule.RDSClient({});

      return {
        async acquireLock(holder) {
          const now = Math.floor(Date.now() / 1000);
          try {
            await dynamodb.send(
              new dynamodbModule.PutItemCommand({
                TableName: process.env.LOCK_TABLE,
                Item: {
                  LockId: { S: process.env.ECS_SERVICE_NAME },
                  Holder: { S: holder },
                  ExpiresAt: { N: String(now + 900) },
                },
                ConditionExpression: "attribute_not_exists(LockId) OR ExpiresAt < :now",
                ExpressionAttributeValues: { ":now": { N: String(now) } },
              }),
            );
          } catch (error) {
            if (error?.name === "ConditionalCheckFailedException") {
              const lockError = new Error("Another staging operation currently holds the lock.");
              lockError.name = "OperationLockUnavailable";
              throw lockError;
            }
            throw error;
          }
        },
        async renewLock(holder) {
          const now = Math.floor(Date.now() / 1000);
          await dynamodb.send(
            new dynamodbModule.UpdateItemCommand({
              TableName: process.env.LOCK_TABLE,
              Key: { LockId: { S: process.env.ECS_SERVICE_NAME } },
              UpdateExpression: "SET ExpiresAt = :expiresAt",
              ConditionExpression: "Holder = :holder AND ExpiresAt >= :now",
              ExpressionAttributeValues: {
                ":holder": { S: holder },
                ":now": { N: String(now) },
                ":expiresAt": { N: String(now + 900) },
              },
            }),
          );
        },
        async releaseLock(holder) {
          try {
            await dynamodb.send(
              new dynamodbModule.DeleteItemCommand({
                TableName: process.env.LOCK_TABLE,
                Key: { LockId: { S: process.env.ECS_SERVICE_NAME } },
                ConditionExpression: "Holder = :holder",
                ExpressionAttributeValues: { ":holder": { S: holder } },
              }),
            );
          } catch (error) {
            if (error?.name !== "ConditionalCheckFailedException") throw error;
          }
        },
        async getOverride() {
          const response = await dynamodb.send(
            new dynamodbModule.GetItemCommand({
              TableName: process.env.LOCK_TABLE,
              Key: { LockId: { S: "manual-override" } },
              ConsistentRead: true,
            }),
          );
          const expiresAt = Number(response.Item?.ExpiresAt?.N ?? 0);
          return { active: expiresAt > Math.floor(Date.now() / 1000) };
        },
        async requestDrain(operationId) {
          const now = Math.floor(Date.now() / 1000);
          await dynamodb.send(
            new dynamodbModule.PutItemCommand({
              TableName: process.env.LOCK_TABLE,
              Item: {
                LockId: { S: "bracket-preview-worker" },
                State: { S: "DRAINING" },
                OperationId: { S: operationId },
                RequestedAt: { N: String(now) },
                ExpiresAt: { N: String(now + 1_200) },
              },
            }),
          );
          return { state: "DRAINING", operationId };
        },
        async getDrain(operationId) {
          const response = await dynamodb.send(
            new dynamodbModule.GetItemCommand({
              TableName: process.env.LOCK_TABLE,
              Key: { LockId: { S: "bracket-preview-worker" } },
              ConsistentRead: true,
            }),
          );
          const item = response.Item;
          if (item?.OperationId?.S !== operationId) {
            return { state: "MISSING", timedOut: true };
          }
          const requestedAt = Number(item.RequestedAt?.N ?? 0);
          return {
            state: item.State?.S ?? "MISSING",
            operationId,
            timedOut: Math.floor(Date.now() / 1000) - requestedAt >= 600,
          };
        },
        async clearDrain(operationId) {
          try {
            await dynamodb.send(
              new dynamodbModule.DeleteItemCommand({
                TableName: process.env.LOCK_TABLE,
                Key: { LockId: { S: "bracket-preview-worker" } },
                ConditionExpression: "OperationId = :operationId",
                ExpressionAttributeValues: { ":operationId": { S: operationId } },
              }),
            );
          } catch (error) {
            if (error?.name !== "ConditionalCheckFailedException") throw error;
          }
        },
        async getRdsStatus() {
          const response = await rds.send(
            new rdsModule.DescribeDBInstancesCommand({
              DBInstanceIdentifier: process.env.RDS_INSTANCE_IDENTIFIER,
            }),
          );
          const status = response.DBInstances?.[0]?.DBInstanceStatus;
          if (!status) throw new Error("The staging RDS instance was not found.");
          return { status };
        },
        async startRds() {
          const response = await rds.send(
            new rdsModule.DescribeDBInstancesCommand({
              DBInstanceIdentifier: process.env.RDS_INSTANCE_IDENTIFIER,
            }),
          );
          const status = response.DBInstances?.[0]?.DBInstanceStatus;
          if (status === "stopped") {
            await rds.send(
              new rdsModule.StartDBInstanceCommand({
                DBInstanceIdentifier: process.env.RDS_INSTANCE_IDENTIFIER,
              }),
            );
          } else if (status !== "available" && status !== "starting") {
            throw new Error(`RDS cannot be started from state ${status ?? "unknown"}.`);
          }
          return { status: status === "stopped" ? "starting" : status };
        },
        async stopRds() {
          const response = await rds.send(
            new rdsModule.DescribeDBInstancesCommand({
              DBInstanceIdentifier: process.env.RDS_INSTANCE_IDENTIFIER,
            }),
          );
          const status = response.DBInstances?.[0]?.DBInstanceStatus;
          if (status === "available") {
            await rds.send(
              new rdsModule.StopDBInstanceCommand({
                DBInstanceIdentifier: process.env.RDS_INSTANCE_IDENTIFIER,
              }),
            );
          } else if (status !== "stopped" && status !== "stopping") {
            throw new Error(`RDS cannot be stopped from state ${status ?? "unknown"}.`);
          }
          return { status: status === "available" ? "stopping" : status };
        },
        async getEcsStatus() {
          const response = await ecs.send(
            new ecsModule.DescribeServicesCommand({
              cluster: process.env.ECS_CLUSTER_NAME,
              services: [process.env.ECS_SERVICE_NAME],
            }),
          );
          const service = response.services?.[0];
          if (response.failures?.length || !service) {
            throw new Error("The staging ECS service was not found.");
          }
          const deployments = service.deployments ?? [];
          const stable =
            service.pendingCount === 0 &&
            service.runningCount === service.desiredCount &&
            (service.desiredCount === 0 ||
              (deployments.length === 1 && deployments[0]?.rolloutState === "COMPLETED"));
          return {
            desiredCount: service.desiredCount,
            runningCount: service.runningCount,
            pendingCount: service.pendingCount,
            stable,
          };
        },
        async setEcsDesiredCount(desiredCount) {
          const response = await ecs.send(
            new ecsModule.DescribeServicesCommand({
              cluster: process.env.ECS_CLUSTER_NAME,
              services: [process.env.ECS_SERVICE_NAME],
            }),
          );
          const service = response.services?.[0];
          if (response.failures?.length || !service) {
            throw new Error("The staging ECS service was not found.");
          }
          if (service.desiredCount !== desiredCount) {
            await ecs.send(
              new ecsModule.UpdateServiceCommand({
                cluster: process.env.ECS_CLUSTER_NAME,
                service: process.env.ECS_SERVICE_NAME,
                desiredCount,
              }),
            );
          }
          return { desiredCount };
        },
        async listRunningTasks() {
          const response = await ecs.send(
            new ecsModule.ListTasksCommand({
              cluster: process.env.ECS_CLUSTER_NAME,
              serviceName: process.env.ECS_SERVICE_NAME,
              desiredStatus: "RUNNING",
            }),
          );
          const taskArns = response.taskArns ?? [];
          return { taskArns, hasTasks: taskArns.length > 0 };
        },
        async verifyStoppedTasks(taskArns) {
          if (taskArns.length === 0) return { verified: true };
          const response = await ecs.send(
            new ecsModule.DescribeTasksCommand({
              cluster: process.env.ECS_CLUSTER_NAME,
              tasks: taskArns,
            }),
          );
          if (response.failures?.length || response.tasks?.length !== taskArns.length) {
            throw new Error("Unable to verify every stopped staging ECS task.");
          }
          const tasks = response.tasks ?? [];
          const unsafeTask = tasks.find(
            (task) =>
              task.lastStatus !== "STOPPED" ||
              task.containers?.some((container) => container.exitCode !== 0),
          );
          if (unsafeTask) {
            throw new Error(
              `ECS task ${unsafeTask.taskArn ?? "unknown"} did not complete graceful shutdown.`,
            );
          }
          return { verified: true };
        },
        async probeHealth() {
          const apiEndpoint = process.env.API_ENDPOINT;
          if (!apiEndpoint) throw new Error("The staging API endpoint is not configured.");
          const checks = ["/api/v1/health", "/api/v1/health/database", "/api/v1/public/settings"];
          for (const path of checks) {
            const response = await fetch(`${apiEndpoint}${path}`, {
              method: "GET",
              signal: AbortSignal.timeout(10_000),
            });
            if (!response.ok) {
              throw new Error(`Staging API check ${path} returned HTTP ${response.status}.`);
            }
          }
          const readyAt = new Date().toISOString();
          console.info(JSON.stringify({ event: "laje152-staging-ready", readyAt, checks }));
          return { readyAt, checks };
        },
        async cleanup(operationId) {
          await this.clearDrain(operationId);
          await this.releaseLock(operationId);
          return { cleaned: true };
        },
      };
    });
  }
  return dependenciesPromise;
}

export async function handler(event) {
  const dependencies = await loadDependencies();
  const operationId = event.operationId;

  if (event.action === "acquireLock") return dependencies.acquireLock(operationId);
  if (event.action === "renewLock") return dependencies.renewLock(operationId);
  if (event.action === "releaseLock") return dependencies.releaseLock(operationId);
  if (event.action === "cleanup") return dependencies.cleanup(operationId);
  if (event.action === "checkOverride") return dependencies.getOverride();
  if (event.action === "requestDrain") return dependencies.requestDrain(operationId);
  if (event.action === "getDrain") return dependencies.getDrain(operationId);
  if (event.action === "clearDrain") return dependencies.clearDrain(operationId);
  if (event.action === "getRdsStatus") return dependencies.getRdsStatus();
  if (event.action === "startRds") return dependencies.startRds();
  if (event.action === "stopRds") return dependencies.stopRds();
  if (event.action === "getEcsStatus") return dependencies.getEcsStatus();
  if (event.action === "setEcsDesiredCount") {
    return dependencies.setEcsDesiredCount(event.desiredCount);
  }
  if (event.action === "listRunningTasks") return dependencies.listRunningTasks();
  if (event.action === "verifyStoppedTasks") {
    return dependencies.verifyStoppedTasks(event.taskArns ?? []);
  }
  if (event.action === "probeHealth") return dependencies.probeHealth();

  throw new Error(`Unsupported staging lifecycle action: ${String(event.action)}.`);
}
