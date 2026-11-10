export async function shutdownApiRuntime(
  closeHttpServer: () => Promise<void>,
  stopWorker: () => Promise<void>,
  closeDatabase: () => Promise<void>,
): Promise<void> {
  await Promise.all([closeHttpServer(), stopWorker()]);
  await closeDatabase();
}
