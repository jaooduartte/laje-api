import type { Request, RequestHandler, Response } from "express";

import type { AuthenticatedRequest } from "./auth.middleware.js";
import {
  parseLoginBody,
  parseLoginIdentifierBody,
  parsePasswordChangeBody,
  parsePasswordSetupBody,
  readCookie,
} from "./auth.schema.js";
import type { AuthService } from "./auth.service.js";

const REFRESH_COOKIE_NAME = "laje_refresh_token";

export class AuthController {
  constructor(private readonly authService: AuthService) {}

  readonly resolveLoginState: RequestHandler = async (request, response, next) => {
    try {
      const { loginIdentifier } = parseLoginIdentifierBody(request.body);
      response
        .status(200)
        .json({ data: await this.authService.resolveLoginState(loginIdentifier) });
    } catch (error) {
      next(error);
    }
  };

  readonly createSession: RequestHandler = async (request, response, next) => {
    try {
      const { loginIdentifier, password } = parseLoginBody(request.body);
      const result = await this.authService.createSession(loginIdentifier, password);
      this.writeRefreshCookie(response, result.refreshToken);
      response.status(200).json({ data: result.payload });
    } catch (error) {
      next(error);
    }
  };

  readonly setupPassword: RequestHandler = async (request, response, next) => {
    try {
      const { loginIdentifier, newPassword } = parsePasswordSetupBody(request.body);
      const result = await this.authService.setupPassword(loginIdentifier, newPassword);
      this.writeRefreshCookie(response, result.refreshToken);
      response.status(200).json({ data: result.payload });
    } catch (error) {
      next(error);
    }
  };

  readonly refreshSession: RequestHandler = async (request, response, next) => {
    try {
      const refreshToken = readCookie(request.header("cookie"), REFRESH_COOKIE_NAME);
      const result = await this.authService.refreshSession(refreshToken);
      this.writeRefreshCookie(response, result.refreshToken);
      response.status(200).json({ data: result.payload });
    } catch (error) {
      next(error);
    }
  };

  readonly deleteSession: RequestHandler = async (request, response, next) => {
    try {
      const principal = this.requirePrincipal(request);
      await this.authService.revokeSession(principal);
      this.clearRefreshCookie(response);
      response.status(204).end();
    } catch (error) {
      next(error);
    }
  };

  readonly getMe: RequestHandler = (request, response, next) => {
    try {
      response.status(200).json({ data: this.requirePrincipal(request).user });
    } catch (error) {
      next(error);
    }
  };

  readonly changePassword: RequestHandler = async (request, response, next) => {
    try {
      const principal = this.requirePrincipal(request);
      const { currentPassword, newPassword } = parsePasswordChangeBody(request.body);
      await this.authService.changePassword(principal, currentPassword, newPassword);
      response.status(204).end();
    } catch (error) {
      next(error);
    }
  };

  private requirePrincipal(request: Request) {
    const principal = (request as AuthenticatedRequest).authPrincipal;
    if (!principal) throw new Error("Authentication middleware did not provide a principal.");
    return principal;
  }

  private writeRefreshCookie(response: Response, token: string): void {
    const config = this.authService.getRefreshCookieConfig();
    response.cookie(REFRESH_COOKIE_NAME, token, {
      httpOnly: true,
      secure: config.secure,
      sameSite: config.secure ? "none" : "lax",
      path: "/api/v1/auth",
      maxAge: config.maxAgeMs,
    });
  }

  private clearRefreshCookie(response: Response): void {
    const config = this.authService.getRefreshCookieConfig();
    response.clearCookie(REFRESH_COOKIE_NAME, {
      httpOnly: true,
      secure: config.secure,
      sameSite: config.secure ? "none" : "lax",
      path: "/api/v1/auth",
    });
  }
}
