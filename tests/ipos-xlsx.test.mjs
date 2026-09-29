import assert from "node:assert/strict";
import test from "node:test";
import * as XLSX from "xlsx";
import { IPOS_HEADERS, parseIposWorkbook } from "../src/lib/ipos/xlsx-parser.ts";
import { chunkIposRows } from "../src/lib/ipos/chunks.ts";

const markers = ["TIPE", "O", "=> PENTING JANGAN HAPUS BARIS INI"];

function workbookBuffer({ sheetName = "Satu Harga", headers = IPOS_HEADERS, data = [] } = {}) {
  const workbook = XLSX.utils.book_new();
  const sheet = XLSX.utils.aoa_to_sheet([markers, headers, ...data]);
  XLSX.utils.book_append_sheet(workbook, sheet, sheetName);
  return XLSX.write(workbook, { type: "buffer", bookType: "xlsx" });
}

test("parses known iPos format, source row numbers, and raw cell values without normalization", () => {
  const values = Array(IPOS_HEADERS.length).fill(null);
  values[0] = " 0001 ";
  values[1] = "bad\u0001barcode";
  values[2] = "  Kopi  ";
  values[6] = 0;
  values[8] = 2.5;
  const parsed = parseIposWorkbook(workbookBuffer({ data: [values, Array(IPOS_HEADERS.length).fill(null), ["SKU-3"]] }));
  assert.deepEqual(parsed.rows.map((row) => row.sourceRowNumber), [3, 4, 5]);
  assert.equal(parsed.rows[0].rawData.KODEITEM, " 0001 ");
  assert.equal(parsed.rows[0].rawData.KODEBARCODE, "bad\u0001barcode");
  assert.equal(parsed.rows[0].rawData.NAMAITEM, "  Kopi  ");
  assert.equal(parsed.rows[0].rawData.HARGAPOKOK, 0);
  assert.equal(parsed.rows[0].rawData.STOK, 2.5);
  assert.equal(parsed.rows[1].rawData.KODEITEM, null);
  assert.equal(parsed.rows[2].rawData.KODEITEM, "SKU-3");
});

test("rejects a missing Satu Harga sheet", () => {
  assert.throws(() => parseIposWorkbook(workbookBuffer({ sheetName: "Sheet1" })), /Satu Harga/);
});

test("rejects wrong, duplicate, and missing headers", () => {
  const wrong = [...IPOS_HEADERS];
  wrong[0] = "WRONG";
  assert.throws(() => parseIposWorkbook(workbookBuffer({ headers: wrong })), /Unexpected iPos header/);
  const missing = IPOS_HEADERS.slice(0, -1);
  assert.throws(() => parseIposWorkbook(workbookBuffer({ headers: missing })), /Missing required iPos headers/);
  const duplicate = [...IPOS_HEADERS];
  duplicate[1] = duplicate[0];
  assert.throws(() => parseIposWorkbook(workbookBuffer({ headers: duplicate })), /Duplicate iPos header/);
});

test("rejects non-XLSX input and incorrect control markers", () => {
  assert.throws(() => parseIposWorkbook(new Uint8Array([1, 2, 3, 4])), /XLSX\/ZIP/);
  const workbook = XLSX.read(workbookBuffer(), { type: "buffer" });
  workbook.Sheets["Satu Harga"].A1.v = "OTHER";
  const changed = XLSX.write(workbook, { type: "buffer", bookType: "xlsx" });
  assert.throws(() => parseIposWorkbook(changed), /control markers/);
});

test("handles the known 5,103-row snapshot size", () => {
  const data = Array.from({ length: 5103 }, (_, index) => [`SKU-${index + 1}`]);
  const parsed = parseIposWorkbook(workbookBuffer({ data }));
  assert.equal(parsed.rows.length, 5103);
  assert.equal(parsed.rows[0].sourceRowNumber, 3);
  assert.equal(parsed.rows.at(-1).sourceRowNumber, 5105);
  assert.equal(parsed.rows.at(-1).rawData.KODEITEM, "SKU-5103");
});

test("splits a 5,103-row snapshot into ordered 100-row inserts", () => {
  const rows = Array.from({ length: 5103 }, (_, index) => index);
  const chunks = chunkIposRows(rows, 100);
  assert.equal(chunks.length, 52);
  assert.deepEqual(chunks.map((chunk) => chunk.length).slice(0, 2), [100, 100]);
  assert.equal(chunks.at(-1).length, 3);
  assert.equal(chunks.flat().length, rows.length);
  assert.deepEqual(chunks.flat(), rows);
});
