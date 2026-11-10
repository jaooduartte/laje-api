import { awsJsonRequest } from "./aws-json.client.js";

export interface SqsMessage {
  messageId: string;
  receiptHandle: string;
  body: string;
  approximateReceiveCount: number;
}

interface SqsResponse {
  Messages?: Array<{
    MessageId?: string;
    ReceiptHandle?: string;
    Body?: string;
    Attributes?: Record<string, string>;
  }>;
}

export class AwsSqsClient {
  constructor(
    private readonly region: string,
    private readonly queueUrl: string,
  ) {}

  async sendMessage(body: string, delaySeconds = 0): Promise<void> {
    await this.request("AmazonSQS.SendMessage", {
      QueueUrl: this.queueUrl,
      MessageBody: body,
      DelaySeconds: delaySeconds,
    });
  }

  async receiveMessages(input: {
    waitTimeSeconds: number;
    visibilityTimeoutSeconds: number;
    maxNumberOfMessages?: number;
  }): Promise<SqsMessage[]> {
    const payload = (await this.request("AmazonSQS.ReceiveMessage", {
      QueueUrl: this.queueUrl,
      MaxNumberOfMessages: input.maxNumberOfMessages ?? 5,
      WaitTimeSeconds: input.waitTimeSeconds,
      VisibilityTimeout: input.visibilityTimeoutSeconds,
      AttributeNames: ["ApproximateReceiveCount"],
    })) as SqsResponse;

    return (payload.Messages ?? []).flatMap((message) => {
      if (!message.MessageId || !message.ReceiptHandle || message.Body == null) {
        return [];
      }
      return [
        {
          messageId: message.MessageId,
          receiptHandle: message.ReceiptHandle,
          body: message.Body,
          approximateReceiveCount: Number(message.Attributes?.ApproximateReceiveCount ?? 1),
        },
      ];
    });
  }

  async deleteMessage(receiptHandle: string): Promise<void> {
    await this.request("AmazonSQS.DeleteMessage", {
      QueueUrl: this.queueUrl,
      ReceiptHandle: receiptHandle,
    });
  }

  async changeMessageVisibility(receiptHandle: string, visibilityTimeoutSeconds: number) {
    await this.request("AmazonSQS.ChangeMessageVisibility", {
      QueueUrl: this.queueUrl,
      ReceiptHandle: receiptHandle,
      VisibilityTimeout: visibilityTimeoutSeconds,
    });
  }

  private async request(target: string, payload: Record<string, unknown>): Promise<unknown> {
    return awsJsonRequest(this.region, "sqs", target, payload);
  }
}
