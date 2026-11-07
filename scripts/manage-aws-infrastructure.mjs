import "dotenv/config";

import { startAwsInfrastructure, stopAwsInfrastructure } from "./aws-infrastructure.mjs";

const command = process.argv[2];

try {
  if (command === "on") {
    await startAwsInfrastructure();
  } else if (command === "off") {
    await stopAwsInfrastructure();
  } else {
    throw new Error("Use: node scripts/manage-aws-infrastructure.mjs <on|off>.");
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
