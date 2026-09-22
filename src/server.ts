import { app } from "./app.js";
import { DEFAULT_PORT } from "./common/constants/app.constants.js";

const configuredPort = Number(process.env.PORT ?? DEFAULT_PORT);

if (!Number.isInteger(configuredPort) || configuredPort <= 0 || configuredPort > 65535) {
  throw new Error("PORT must be a valid TCP port between 1 and 65535.");
}

app.listen(configuredPort, () => {
  console.log(`LAJE API listening on http://localhost:${configuredPort}/api/v1`);
});
