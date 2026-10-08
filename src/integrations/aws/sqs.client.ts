import { createHash, createHmac } from "node:crypto";

interface AwsCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
  expiration?: string;
}

interface EcsCredentialPayload {
  AccessKeyId?: string;
  SecretAccessKey?: string;
  Token?: string;
  Expiration?: string;
}

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

let cachedCredentials: AwsCredentials | null = null;

function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function hmac(key: Buffer | string, value: string): Buffer {
  return createHmac("sha256", key).update(value, "utf8").digest();
}

function encodePath(path: string): string {
  return path
    .split("/")
    .map((part) => encodeURIComponent(part))
    .join("/");
}

function resolveCredentialEndpoint(): string | null {
  const fullUri = process.env.AWS_CONTAINER_CREDENTIALS_FULL_URI?.trim();
  if (fullUri) return fullUri;

  const relativeUri = process.env.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI?.trim();
  return relativeUri ? `http://169.254.170.2${relativeUri}` : null;
}

function environmentCredentials(): AwsCredentials | null {
  const accessKeyId = process.env.AWS_ACCESS_KEY_ID?.trim();
  const secretAccessKey = process.env.AWS_SECRET_ACCESS_KEY?.trim();

  if (!accessKeyId || !secretAccessKey) return null;

  const sessionToken = process.env.AWS_SESSION_TOKEN?.trim();
  return {
    accessKeyId,
    secretAccessKey,
    ...(sessionToken ? { sessionToken } : {}),
  };
}

function credentialsAreFresh(credentials: AwsCredentials): boolean {
  if (!credentials.expiration) return true;
  const expiresAt = new Date(credentials.expiration).getTime();
  return Number.isFinite(expiresAt) && expiresAt - Date.now() > 5 * 60_000;
}

async function loadCredentials(): Promise<AwsCredentials> {
  const fromEnvironment = environmentCredentials();
  if (fromEnvironment) return fromEnvironment;

  if (cachedCredentials && credentialsAreFresh(cachedCredentials)) {
    return cachedCredentials;
  }

  const endpoint = resolveCredentialEndpoint();
  if (!endpoint) {
    throw new Error("AWS credentials are unavailable for the SQS worker.");
  }

  const response = await fetch(endpoint);
  if (!response.ok) {
    throw new Error(`Unable to load ECS task credentials: HTTP ${response.status}.`);
  }

  const payload = (await response.json()) as EcsCredentialPayload;
  if (!payload.AccessKeyId || !payload.SecretAccessKey) {
    throw new Error("ECS task credentials response is incomplete.");
  }

  const resolvedCredentials: AwsCredentials = {
    accessKeyId: payload.AccessKeyId,
    secretAccessKey: payload.SecretAccessKey,
    ...(payload.Token ? { sessionToken: payload.Token } : {}),
    ...(payload.Expiration ? { expiration: payload.Expiration } : {}),
  };
  cachedCredentials = resolvedCredentials;
  return resolvedCredentials;
}

function formatAmzDate(now: Date): { amzDate: string; dateStamp: string } {
  const iso = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  return {
    amzDate: iso,
    dateStamp: iso.slice(0, 8),
  };
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
    const credentials = await loadCredentials();
    const body = JSON.stringify(payload);
    const endpoint = new URL(`https://sqs.${this.region}.amazonaws.com/`);
    const now = new Date();
    const { amzDate, dateStamp } = formatAmzDate(now);

    const headers: Record<string, string> = {
      "content-type": "application/x-amz-json-1.0",
      host: endpoint.host,
      "x-amz-date": amzDate,
      "x-amz-target": target,
    };

    if (credentials.sessionToken) {
      headers["x-amz-security-token"] = credentials.sessionToken;
    }

    const signedHeaderNames = Object.keys(headers).sort();
    const canonicalHeaders = signedHeaderNames
      .map((name) => `${name}:${headers[name]!.trim()}\n`)
      .join("");
    const signedHeaders = signedHeaderNames.join(";");
    const canonicalRequest = [
      "POST",
      encodePath(endpoint.pathname),
      "",
      canonicalHeaders,
      signedHeaders,
      sha256(body),
    ].join("\n");

    const credentialScope = `${dateStamp}/${this.region}/sqs/aws4_request`;
    const stringToSign = [
      "AWS4-HMAC-SHA256",
      amzDate,
      credentialScope,
      sha256(canonicalRequest),
    ].join("\n");

    const dateKey = hmac(`AWS4${credentials.secretAccessKey}`, dateStamp);
    const regionKey = hmac(dateKey, this.region);
    const serviceKey = hmac(regionKey, "sqs");
    const signingKey = hmac(serviceKey, "aws4_request");
    const signature = createHmac("sha256", signingKey).update(stringToSign, "utf8").digest("hex");

    const authorization =
      `AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/${credentialScope}, ` +
      `SignedHeaders=${signedHeaders}, Signature=${signature}`;

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        ...headers,
        authorization,
      },
      body,
    });

    const responseBody = await response.text();
    if (!response.ok) {
      throw new Error(
        `SQS request ${target} failed with HTTP ${response.status}: ${responseBody.slice(0, 500)}`,
      );
    }

    return responseBody ? (JSON.parse(responseBody) as unknown) : {};
  }
}
