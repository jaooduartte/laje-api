import type { DatabaseQueryExecutor } from "./types.js";

export abstract class BaseRepository {
  protected constructor(protected readonly database: DatabaseQueryExecutor) {}
}
