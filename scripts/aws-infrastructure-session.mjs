export async function runWithAwsInfrastructure(start, run, stop) {
  const resourcesStartedBySession = await start();
  let result;
  let runError;
  let cleanupError;

  try {
    result = await run(resourcesStartedBySession);
  } catch (error) {
    runError = error;
  }

  try {
    await stop(resourcesStartedBySession);
  } catch (error) {
    cleanupError = error;
  }

  if (runError && cleanupError) {
    throw new AggregateError(
      [runError, cleanupError],
      "A sessão AWS falhou e também houve uma falha ao limpar os recursos iniciados.",
    );
  }
  if (runError) throw runError;
  if (cleanupError) throw cleanupError;
  return result;
}
