import cors from "cors";
import express from "express";

import { API_PREFIX } from "./common/constants/app.constants.js";
import { errorHandler } from "./common/middlewares/error-handler.middleware.js";
import { notFoundHandler } from "./common/middlewares/not-found.middleware.js";
import { appConfig } from "./config/app.config.js";
import { apiRouter } from "./routes/index.js";

export const app = express();

app.disable("x-powered-by");
app.use(
  cors({
    origin: appConfig.corsOrigins,
    credentials: true,
  }),
);
app.use(express.json());

app.use(API_PREFIX, apiRouter);

app.use(notFoundHandler);
app.use(errorHandler);
