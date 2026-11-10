import { awsJsonRequest } from "./aws-json.client.js";

export interface BracketPreviewWorkerDrainState {
  state: string;
  operationId: string;
}

interface DynamoDbItem {
  State?: { S?: string };
  OperationId?: { S?: string };
}

interface DynamoDbGetItemResponse {
  Item?: DynamoDbItem;
}

export class AwsDynamoDbClient {
  constructor(
    private readonly region: string,
    private readonly tableName: string,
  ) {}

  async getBracketPreviewWorkerDrainState(): Promise<BracketPreviewWorkerDrainState | null> {
    const response = (await awsJsonRequest(this.region, "dynamodb", "DynamoDB_20120810.GetItem", {
      TableName: this.tableName,
      Key: { LockId: { S: "bracket-preview-worker" } },
      ConsistentRead: true,
    })) as DynamoDbGetItemResponse;

    const state = response.Item?.State?.S;
    const operationId = response.Item?.OperationId?.S;
    if (!state || !operationId) return null;

    return { state, operationId };
  }

  async markBracketPreviewWorkerDrained(operationId: string): Promise<boolean> {
    try {
      await awsJsonRequest(this.region, "dynamodb", "DynamoDB_20120810.UpdateItem", {
        TableName: this.tableName,
        Key: { LockId: { S: "bracket-preview-worker" } },
        UpdateExpression: "SET #state = :drained",
        ConditionExpression: "#state = :draining AND OperationId = :operationId",
        ExpressionAttributeNames: { "#state": "State" },
        ExpressionAttributeValues: {
          ":draining": { S: "DRAINING" },
          ":drained": { S: "DRAINED" },
          ":operationId": { S: operationId },
        },
      });
      return true;
    } catch (error) {
      if (error instanceof Error && error.name === "ConditionalCheckFailedException") return false;
      throw error;
    }
  }
}
