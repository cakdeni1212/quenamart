import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { IPOS_SALES_MAX_FILE_BYTES, validateIposSalesUpload } from "../src/lib/ipos-sales/upload-validation.ts";

test("valid .xls and .xlsx uploads under 25 MiB pass application validation", () => {
  assert.equal(validateIposSalesUpload("laporan.xls", 1024), null);
  assert.equal(validateIposSalesUpload("laporan.xlsx", IPOS_SALES_MAX_FILE_BYTES), null);
});

test("files above 25 MiB receive the friendly size message", () => {
  assert.equal(validateIposSalesUpload("laporan.xls", IPOS_SALES_MAX_FILE_BYTES + 1), "Ukuran file maksimal 25 MB.");
});

test("unsupported extensions are rejected before parsing", () => {
  assert.equal(validateIposSalesUpload("laporan.csv", 1024), "Format file belum didukung. Pilih file .xls atau .xlsx.");
});

test("Next Server Actions retain a bounded request limit above the 25 MiB file limit for multipart overhead", () => {
  const config = readFileSync(new URL("../next.config.ts", import.meta.url), "utf8");
  assert.match(config, /experimental\s*:\s*\{[\s\S]*serverActions\s*:\s*\{[\s\S]*bodySizeLimit\s*:\s*["']26mb["']/);
  assert.match(config, /multipart framing/);
});
