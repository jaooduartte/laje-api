export interface ApiErrorDetail {
  field?: string;
  code: string;
  message: string;
}

export class ApiError extends Error {
  readonly statusCode: number;
  readonly code: string;
  readonly details: ApiErrorDetail[] | undefined;

  constructor(statusCode: number, code: string, message: string, details?: ApiErrorDetail[]) {
    super(message);
    this.name = "ApiError";
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
  }
}
