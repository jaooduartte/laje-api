import assert from "node:assert/strict";
import test from "node:test";

import { splitSqlStatements } from "../../src/operations/sql-script.js";

test("splits ordinary SQL statements", () => {
  assert.deepEqual(splitSqlStatements("SELECT 1; SELECT 2;"), ["SELECT 1", "SELECT 2"]);
});

test("keeps semicolons inside dollar quoted function bodies", () => {
  const script = `
CREATE OR REPLACE FUNCTION public.sample()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM 1;
  PERFORM 2;
END;
$function$;

SELECT 3;
`;

  const statements = splitSqlStatements(script);
  assert.equal(statements.length, 2);
  assert.match(statements[0] ?? "", /PERFORM 1;/);
  assert.match(statements[0] ?? "", /PERFORM 2;/);
  assert.equal(statements[1], "SELECT 3");
});

test("keeps semicolons in strings and nested block comments", () => {
  const script = `
SELECT 'a;b';
/* outer ;
   /* inner ; */
*/
SELECT "semi;colon";
`;

  const statements = splitSqlStatements(script);
  assert.equal(statements.length, 2);
  assert.match(statements[0] ?? "", /'a;b'/);
  assert.match(statements[1] ?? "", /"semi;colon"/);
});

test("rejects unterminated SQL literals", () => {
  assert.throws(
    () => splitSqlStatements("SELECT $function$unterminated;"),
    /unterminated SQL literal or comment/,
  );
});
