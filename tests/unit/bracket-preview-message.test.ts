import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyBracketPreviewDlqMessage,
  parseBracketPreviewQueueMessage,
} from "../../src/modules/bracket-preview/bracket-preview-message.js";

test("accepts periodic MAINTENANCE payloads exactly as the worker does", () => {
  assert.deepEqual(parseBracketPreviewQueueMessage('{"type":"MAINTENANCE"}'), {
    type: "MAINTENANCE",
  });
  assert.equal(classifyBracketPreviewDlqMessage('{"type":"MAINTENANCE"}'), "MAINTENANCE");
});

test("recognizes resumable PROCESS_PREVIEW jobs without reprocessing them", () => {
  const body = '{"type":"PROCESS_PREVIEW","jobId":"123e4567-e89b-12d3-a456-426614174000"}';
  assert.deepEqual(parseBracketPreviewQueueMessage(body), {
    type: "PROCESS_PREVIEW",
    jobId: "123e4567-e89b-12d3-a456-426614174000",
  });
  assert.equal(classifyBracketPreviewDlqMessage(body), "PROCESS_PREVIEW");
});

test("rejects invalid, unsupported and incomplete messages for separate investigation", () => {
  for (const body of [
    "",
    "{not-json",
    '{"type":"UNKNOWN"}',
    '{"type":"PROCESS_PREVIEW"}',
    '{"type":"PROCESS_PREVIEW","jobId":""}',
    '{"type":"PROCESS_PREVIEW","jobId":42}',
    "null",
  ]) {
    assert.equal(classifyBracketPreviewDlqMessage(body), "INVALID");
    assert.throws(() => parseBracketPreviewQueueMessage(body));
  }
});
