export type ReviewIntentStorage = Pick<Storage, "length" | "key" | "setItem" | "removeItem">;

const PREFIX = "quena:product-review-intent:";

export function reviewIntentStoragePrefix(productId: string, field: string) {
  return `${PREFIX}${productId}:${field}:`;
}

export function listStoredReviewIntentIds(storage: ReviewIntentStorage, productId: string, field: string): string[] {
  const prefix = reviewIntentStoragePrefix(productId, field);
  const ids: string[] = [];
  for (let index = 0; index < storage.length; index += 1) {
    const key = storage.key(index);
    if (key?.startsWith(prefix)) ids.push(key.slice(prefix.length));
  }
  return ids;
}

export function storeReviewIntentId(storage: ReviewIntentStorage, productId: string, field: string, requestId: string) {
  storage.setItem(`${reviewIntentStoragePrefix(productId, field)}${requestId}`, "1");
}

export function forgetReviewIntentId(storage: ReviewIntentStorage, productId: string, field: string, requestId: string) {
  storage.removeItem(`${reviewIntentStoragePrefix(productId, field)}${requestId}`);
}

export async function restoreStoredReviewIntent<T>(
  storage: ReviewIntentStorage,
  productId: string,
  field: string,
  lookup: (requestId: string) => Promise<T | null>,
  alreadyReflected: (value: T) => boolean = () => false,
): Promise<{ requestId: string; value: T } | null> {
  const ids = listStoredReviewIntentIds(storage, productId, field).reverse();
  for (const requestId of ids) {
    const value = await lookup(requestId);
    if (value !== null && !alreadyReflected(value)) return { requestId, value };
    forgetReviewIntentId(storage, productId, field, requestId);
  }
  return null;
}
