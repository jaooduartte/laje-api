import { app } from "./app.js";
import { appConfig } from "./config/app.config.js";
import { database } from "./database/index.js";
import {
  startBracketPreviewWorker,
  stopBracketPreviewWorker,
} from "./modules/bracket-preview/bracket-preview.runtime.js";

async function startServer(): Promise<void> {
  await database.checkConnection();

  const server = app.listen(appConfig.port, () => {
    console.log(
      `LAJE API listening on http://localhost:${appConfig.port}/api/v1 (${appConfig.environment})`,
    );
    startBracketPreviewWorker();
  });

  let shuttingDown = false;

  const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;

    console.log(`Received ${signal}. Closing HTTP server and PostgreSQL connections.`);
    stopBracketPreviewWorker();

    await new Promise<void>((resolve, reject) => {
      server.close((error) => {
        if (error) reject(error);
        else resolve();
      });
    });

    await database.close();
  };

  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.once(signal, () => {
      void shutdown(signal).catch((error: unknown) => {
        console.error("Failed to shut down LAJE API cleanly.", error);
        process.exitCode = 1;
      });
    });
  }
}

void startServer().catch(async (error: unknown) => {
  console.error("LAJE API failed to connect to PostgreSQL during startup.", error);

  try {
    await database.close();
  } catch (closeError: unknown) {
    console.error("Failed to close PostgreSQL connections after startup failure.", closeError);
  }

  process.exitCode = 1;
});
