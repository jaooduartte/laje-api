import { Router } from "express";

export const apiRouter = Router();

apiRouter.get("/", (_request, response) => {
  response.status(200).json({
    service: "laje-api",
    version: "v1",
    status: "ready",
  });
});
