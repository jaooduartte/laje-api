export function splitSqlStatements(script: string): string[] {
  const statements: string[] = [];
  let current = "";
  let index = 0;
  let singleQuoted = false;
  let doubleQuoted = false;
  let lineComment = false;
  let blockCommentDepth = 0;
  let dollarTag: string | null = null;

  while (index < script.length) {
    const character = script[index]!;
    const next = script[index + 1] ?? "";

    if (lineComment) {
      current += character;
      if (character === "\n") lineComment = false;
      index += 1;
      continue;
    }

    if (blockCommentDepth > 0) {
      current += character;
      if (character === "/" && next === "*") {
        current += next;
        blockCommentDepth += 1;
        index += 2;
        continue;
      }
      if (character === "*" && next === "/") {
        current += next;
        blockCommentDepth -= 1;
        index += 2;
        continue;
      }
      index += 1;
      continue;
    }

    if (dollarTag) {
      if (script.startsWith(dollarTag, index)) {
        current += dollarTag;
        index += dollarTag.length;
        dollarTag = null;
      } else {
        current += character;
        index += 1;
      }
      continue;
    }

    if (singleQuoted) {
      current += character;
      if (character === "'" && next === "'") {
        current += next;
        index += 2;
        continue;
      }
      if (character === "'") singleQuoted = false;
      index += 1;
      continue;
    }

    if (doubleQuoted) {
      current += character;
      if (character === '"' && next === '"') {
        current += next;
        index += 2;
        continue;
      }
      if (character === '"') doubleQuoted = false;
      index += 1;
      continue;
    }

    if (character === "-" && next === "-") {
      current += character + next;
      lineComment = true;
      index += 2;
      continue;
    }

    if (character === "/" && next === "*") {
      current += character + next;
      blockCommentDepth = 1;
      index += 2;
      continue;
    }

    if (character === "'") {
      current += character;
      singleQuoted = true;
      index += 1;
      continue;
    }

    if (character === '"') {
      current += character;
      doubleQuoted = true;
      index += 1;
      continue;
    }

    if (character === "$") {
      const match = script.slice(index).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);
      if (match) {
        dollarTag = match[0];
        current += dollarTag;
        index += dollarTag.length;
        continue;
      }
    }

    if (character === ";") {
      const statement = current.trim();
      if (statement) statements.push(statement);
      current = "";
      index += 1;
      continue;
    }

    current += character;
    index += 1;
  }

  const trailing = current.trim();
  if (trailing) statements.push(trailing);

  if (singleQuoted || doubleQuoted || dollarTag || blockCommentDepth > 0) {
    throw new Error("Operational migration contains an unterminated SQL literal or comment.");
  }

  return statements;
}
