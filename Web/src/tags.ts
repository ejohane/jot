/** The same deliberately small grammar is implemented by InlineTags.swift. See README.md. */
export type TagMatch = { from: number; to: number; name: string };

const tagPattern = /(^|[\s([{\"'])#([A-Za-z][A-Za-z0-9_-]*)/gm;
const fencePattern = /^ {0,3}(`{3,}|~{3,})/;

export function findInlineTags(source: string): TagMatch[] {
  const masked = source.split("");
  let fence: { marker: string; length: number } | undefined;
  let offset = 0;
  for (const line of source.split("\n")) {
    const fenceMatch = fencePattern.exec(line);
    if (fence) {
      masked.fill(" ", offset, offset + line.length);
      if (fenceMatch && fenceMatch[1][0] === fence.marker && fenceMatch[1].length >= fence.length) fence = undefined;
    } else if (fenceMatch) {
      fence = { marker: fenceMatch[1][0], length: fenceMatch[1].length };
      masked.fill(" ", offset, offset + line.length);
    } else {
      for (let i = 0; i < line.length;) {
        if (line[i] === "\\") { i += 2; continue; }
        if (line[i] === "`" && line[i - 1] !== "`") {
          let end = i + 1;
          while (line[end] === "`") end++;
          const run = line.slice(i, end);
          let close = line.indexOf(run, end);
          while (close >= 0 && (line[close - 1] === "`" || line[close + run.length] === "`")) close = line.indexOf(run, close + run.length);
          if (close >= 0) { masked.fill(" ", offset + i, offset + close + run.length); i = close + run.length; continue; }
          i = end; continue;
        }
        if (line[i] === "]" && line[i + 1] === "(") {
          let depth = 1, j = i + 2;
          for (; j < line.length && depth; j++) {
            if (line[j] === "\\") { j++; continue; }
            if (line[j] === "(") depth++;
            if (line[j] === ")") depth--;
          }
          masked.fill(" ", offset + i + 1, offset + j); i = j; continue;
        }
        i++;
      }
    }
    offset += line.length + 1;
  }
  const safe = masked.join("");
  const tags: TagMatch[] = [];
  for (const match of safe.matchAll(tagPattern)) {
    const from = match.index + match[1].length;
    if (from > 0 && source[from - 1] === "\\") continue;
    tags.push({ from, to: from + match[2].length + 1, name: source.slice(from + 1, from + match[2].length + 1) });
  }
  return tags;
}
