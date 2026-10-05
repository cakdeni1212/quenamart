export function invoiceLineSubtotal(quantity: number, purchaseUnitPrice: number) {
  if (!Number.isFinite(quantity) || quantity <= 0 || !Number.isFinite(purchaseUnitPrice) || purchaseUnitPrice < 0) return null;
  return Math.round((quantity * purchaseUnitPrice + Number.EPSILON) * 100) / 100;
}

export function invoiceSystemTotal(lines: Array<{ quantity: number; purchaseUnitPrice: number }>) {
  return Math.round(lines.reduce((sum, line) => sum + (invoiceLineSubtotal(line.quantity, line.purchaseUnitPrice) ?? 0), 0) * 100) / 100;
}

export function invoiceTotalDifference(systemTotal: number, supplierTotal: number) {
  return Math.round((supplierTotal - systemTotal) * 100) / 100;
}
