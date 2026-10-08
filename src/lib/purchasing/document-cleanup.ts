export type CancelledInvoiceDocument = { documentId?: unknown; storagePath?: unknown };

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isCancelledInvoiceDocumentPath(invoiceId: string, storagePath: string) {
  if (!uuid.test(invoiceId)) return false;
  return new RegExp(`^invoices/${invoiceId}/[0-9a-fA-F-]{36}\\.(jpg|jpeg|png|webp|pdf)$`, "i").test(storagePath);
}

export async function cleanupCancelledInvoiceDocuments(
  invoiceId: string,
  documents: CancelledInvoiceDocument[],
  removeObject: (storagePath: string) => Promise<boolean>,
  markCleanup: (documentId: string, deleted: boolean) => Promise<boolean>,
) {
  let pending = false;
  for (const document of documents) {
    if (typeof document.documentId !== "string" || !uuid.test(document.documentId)
        || typeof document.storagePath !== "string" || !isCancelledInvoiceDocumentPath(invoiceId, document.storagePath)) {
      pending = true;
      continue;
    }
    let deleted = false;
    try { deleted = await removeObject(document.storagePath); } catch { deleted = false; }
    let marked = false;
    try { marked = await markCleanup(document.documentId, deleted); } catch { marked = false; }
    if (!deleted || !marked) pending = true;
  }
  return pending;
}
