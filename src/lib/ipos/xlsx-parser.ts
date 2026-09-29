import * as XLSX from "xlsx";

export const IPOS_SHEET_NAME = "Satu Harga";
export const IPOS_HEADERS = [
  "KODEITEM",
  "KODEBARCODE",
  "NAMAITEM",
  "JENIS",
  "MEREK",
  "SATUAN",
  "HARGAPOKOK",
  "HARGAJUAL",
  "STOK",
  "STOKMIN",
  "TIPE",
  "SERIAL",
  "RAK",
  "DEPT",
  "SUPPLIER1",
  "KETERANGAN",
  "POIN",
  "KOMISISALES",
  "KONSINYASI",
  "SISTEMHPP",
  "JENISPAJAK",
  "PAJAKINCLUDE",
  "OPT",
  "KODEREFERENSI",
] as const;

export type IposRawRow = Record<(typeof IPOS_HEADERS)[number], string | number | boolean | null>;

export type ParsedIposWorkbook = {
  rows: Array<{ sourceRowNumber: number; rawData: IposRawRow }>;
  sourceSheet: typeof IPOS_SHEET_NAME;
  headerRowNumber: 2;
  firstDataRowNumber: 3;
};

const MAX_XLSX_BYTES = 25 * 1024 * 1024;

function cellValue(sheet: XLSX.WorkSheet, row: number, column: number): unknown {
  const address = XLSX.utils.encode_cell({ r: row, c: column });
  const value = sheet[address]?.v;
  return value === undefined ? null : value;
}

function isPopulated(value: unknown) {
  return value !== null && value !== undefined && value !== "";
}

function asJsonScalar(value: unknown, address: string): string | number | boolean | null {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  throw new Error(`Unsupported XLSX cell value at ${address}.`);
}

export function parseIposWorkbook(input: Uint8Array): ParsedIposWorkbook {
  if (input.byteLength === 0) throw new Error("The XLSX workbook is empty.");
  if (input.byteLength > MAX_XLSX_BYTES) throw new Error("The XLSX workbook exceeds the 25 MiB bucket limit.");
  if (input.byteLength < 4 || input[0] !== 0x50 || input[1] !== 0x4b) {
    throw new Error("The uploaded object is not an XLSX/ZIP container.");
  }

  let workbook: XLSX.WorkBook;
  try {
    workbook = XLSX.read(input, { type: "array", raw: true, cellDates: false, cellFormula: true });
  } catch {
    throw new Error("The XLSX workbook could not be parsed.");
  }

  const sheet = workbook.Sheets[IPOS_SHEET_NAME];
  if (!sheet) throw new Error(`The workbook must contain the '${IPOS_SHEET_NAME}' sheet.`);
  if (cellValue(sheet, 0, 0) !== "TIPE" || cellValue(sheet, 0, 1) !== "O"
    || cellValue(sheet, 0, 2) !== "=> PENTING JANGAN HAPUS BARIS INI") {
    throw new Error("The iPos control markers in row 1 are missing or do not match.");
  }

  const range = sheet["!ref"] ? XLSX.utils.decode_range(sheet["!ref"]) : null;
  if (!range || range.e.r < 1) throw new Error("The workbook is missing its row 2 header.");
  const columnByHeader = new Map<string, number>();
  for (let column = range.s.c; column <= range.e.c; column += 1) {
    const value = cellValue(sheet, 1, column);
    if (!isPopulated(value)) continue;
    if (typeof value !== "string" || !(IPOS_HEADERS as readonly string[]).includes(value)) {
      throw new Error(`Unexpected iPos header in column ${XLSX.utils.encode_col(column)}.`);
    }
    if (columnByHeader.has(value)) throw new Error(`Duplicate iPos header '${value}'.`);
    columnByHeader.set(value, column);
  }
  const missingHeaders = IPOS_HEADERS.filter((header) => !columnByHeader.has(header));
  if (missingHeaders.length) throw new Error(`Missing required iPos headers: ${missingHeaders.join(", ")}.`);

  const sourceColumns = new Set(columnByHeader.values());
  let lastDataRow = 1;
  for (let row = 2; row <= range.e.r; row += 1) {
    let hasValue = false;
    for (let column = range.s.c; column <= range.e.c; column += 1) {
      const value = cellValue(sheet, row, column);
      if (isPopulated(value)) {
        hasValue = true;
        if (!sourceColumns.has(column)) {
          throw new Error(`Unexpected populated cell outside the source headers at ${XLSX.utils.encode_cell({ r: row, c: column })}.`);
        }
      }
    }
    if (hasValue) lastDataRow = row;
  }

  const rows: ParsedIposWorkbook["rows"] = [];
  for (let row = 2; row <= lastDataRow; row += 1) {
    const rawData = {} as IposRawRow;
    for (const header of IPOS_HEADERS) {
      const column = columnByHeader.get(header)!;
      const address = XLSX.utils.encode_cell({ r: row, c: column });
      rawData[header] = asJsonScalar(cellValue(sheet, row, column), address);
    }
    rows.push({ sourceRowNumber: row + 1, rawData });
  }

  return { rows, sourceSheet: IPOS_SHEET_NAME, headerRowNumber: 2, firstDataRowNumber: 3 };
}
