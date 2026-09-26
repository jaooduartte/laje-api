import { app } from "./app.js";
import { appConfig } from "./config/app.config.js";

app.listen(appConfig.port, () => {
  console.log(
    `LAJE API listening on http://localhost:${appConfig.port}/api/v1 (${appConfig.environment})`,
  );
});
