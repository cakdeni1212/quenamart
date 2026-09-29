export const AUDIT_FINDINGS = {
  MISSING_BARCODE: "Barcode kosong",
  MALFORMED_BARCODE: "Barcode tidak valid",
  ZERO_OR_MISSING_HPP: "HPP kosong / nol",
  SELLING_PRICE_BELOW_HPP: "Harga jual di bawah HPP",
  ZERO_STOCK: "Stok kosong",
  STOCK_AT_OR_BELOW_MINIMUM: "Stok pada / di bawah minimum",
  MISSING_RACK: "Rak belum diisi",
  DUPLICATE_PRODUCT_NAME: "Nama produk ganda",
} as const;

export const AUDIT_FIELDS = {
  barcode: "Barcode",
  rack_label: "Rak",
  hpp: "HPP",
  selling_price: "Harga jual",
  quantity: "Stok",
  minimum_quantity: "Stok minimum",
  name: "Nama produk",
} as const;

export type AuditFindingCode = keyof typeof AUDIT_FINDINGS;
export type AuditFieldKey = keyof typeof AUDIT_FIELDS;

const findingField: Record<AuditFindingCode, AuditFieldKey> = {
  MISSING_BARCODE: "barcode",
  MALFORMED_BARCODE: "barcode",
  ZERO_OR_MISSING_HPP: "hpp",
  SELLING_PRICE_BELOW_HPP: "selling_price",
  ZERO_STOCK: "quantity",
  STOCK_AT_OR_BELOW_MINIMUM: "minimum_quantity",
  MISSING_RACK: "rack_label",
  DUPLICATE_PRODUCT_NAME: "name",
};

export type AuditQueryValue = string | string[] | undefined;

export type AuditContext = {
  finding: AuditFindingCode | null;
  field: AuditFieldKey | null;
  invalid: boolean;
};

function singleValue(value: AuditQueryValue): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

export function parseAuditContext(
  findingParam: AuditQueryValue,
  fieldParam: AuditQueryValue,
  activeFindings: readonly string[],
): AuditContext {
  let invalid = Array.isArray(findingParam) || Array.isArray(fieldParam);
  const findingValue = singleValue(findingParam);
  const fieldValue = singleValue(fieldParam);

  let finding: AuditFindingCode | null = null;
  if (findingParam !== undefined) {
    if (findingValue && findingValue in AUDIT_FINDINGS && activeFindings.includes(findingValue)) {
      finding = findingValue as AuditFindingCode;
    } else {
      invalid = true;
    }
  }

  let field: AuditFieldKey | null = null;
  if (fieldParam !== undefined) {
    if (fieldValue && fieldValue in AUDIT_FIELDS) field = fieldValue as AuditFieldKey;
    else invalid = true;
  }

  if (finding && !field) field = findingField[finding];
  if (finding && field && findingField[finding] !== field) {
    invalid = true;
    field = findingField[finding];
  }

  return { finding: invalid && findingParam !== undefined && !finding ? null : finding, field: invalid && fieldParam !== undefined && !field ? null : field, invalid };
}

export function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}
