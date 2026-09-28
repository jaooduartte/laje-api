export interface ApplicationHealthResponse {
  service: "laje-api";
  status: "ok";
}

export type DatabaseHealthResponse =
  | {
      database: "reachable";
      status: "ok";
    }
  | {
      database: "unreachable";
      status: "unavailable";
    };
