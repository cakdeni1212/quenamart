export function chunkIposRows<T>(rows: readonly T[], chunkSize: number) {
  if (!Number.isInteger(chunkSize) || chunkSize < 1) {
    throw new Error("Chunk size must be a positive integer.");
  }
  const chunks: T[][] = [];
  for (let offset = 0; offset < rows.length; offset += chunkSize) {
    chunks.push(rows.slice(offset, offset + chunkSize));
  }
  return chunks;
}
