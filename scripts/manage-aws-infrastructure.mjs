import "dotenv/config";

import { startAwsInfrastructure, stopAwsInfrastructure } from "./aws-infrastructure.mjs";

const command = process.argv[2];
const options = process.argv.slice(3);

try {
  if (command === "on") {
    const allowScheduledShutdown =
      options.length === 1 && options[0] === "--allow-scheduled-shutdown";
    if (options.length > 0 && !allowScheduledShutdown) {
      throw new Error(
        "Use: node scripts/manage-aws-infrastructure.mjs on [--allow-scheduled-shutdown].",
      );
    }
    await startAwsInfrastructure({ allowScheduledShutdown });
  } else if (command === "off" && options.length === 0) {
    await stopAwsInfrastructure();
  } else {
    throw new Error(
      "Use: node scripts/manage-aws-infrastructure.mjs <on [--allow-scheduled-shutdown]|off>.",
    );
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
