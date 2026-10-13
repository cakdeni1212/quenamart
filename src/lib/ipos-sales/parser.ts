import * as XLSX from "xlsx";

const MAX_FILE_BYTES = 25 * 1024 * 1024;
const TX_NUMBER = /^\d{6}\/[^/\s]+\/[^/\s]+\/\d{4}$/;

export type IposSalesLine = {
  sourceRowNumber: number;
  rawSku: string;
  rawItemName: string;
  rawQuantity: string;
  rawUnit: string | null;
  rawUnitPrice: string;
  rawDiscountPercent: string;
  rawLineTotal: string;
};

export type IposSalesTransaction = {
  sourceRowNumber: number;
  sourceTransactionNumber: string;
  sourceOccurredAt: string;
  lines: IposSalesLine[];
  detailQuantity: string;
  detailAmount: string;
  sourceTransactionTotal: string;
  sourceDiscountTotal: string;
  sourceTaxTotal: string;
  sourceFeeTotal: string;
};

export type ParsedIposSalesWorkbook = {
  sheetName: string;
  reportFrom: string;
  reportTo: string;
  transactions: IposSalesTransaction[];
  footer: { quantity: string; subtotal: string; discount: string; tax: string; fee: string; grandTotal: string };
  reconciliation: {
    detailQuantity: string;
    footerQuantity: string;
    detailAmount: string;
    transactionTotal: string;
    footerSubtotal: string;
    footerGrandTotal: string;
    isReconciled: boolean;
    differences: Array<{ key: string; expected: string; actual: string; difference: string }>;
  };
  summary: { transactionCount: number; saleLineCount: number; totalQuantity: string; totalAmount: string; uniqueSkuCount: number; firstOccurredAt: string; lastOccurredAt: string };
};

function cell(sheet: XLSX.WorkSheet, row: number, col: number): unknown {
  return sheet[XLSX.utils.encode_cell({ r: row, c: col })]?.v ?? null;
}

function amount(value: unknown, label: string): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n) || n < 0 || n >= 1_000_000_000_000) throw new Error(`Nilai ${label} pada laporan tidak valid.`);
  // Workbook monetary cells are Rupiah with at most two decimal places.
  const cents = Math.round((n + Number.EPSILON) * 100);
  if (Math.abs(n * 100 - cents) > 0.00001) throw new Error(`Presisi ${label} pada laporan tidak didukung.`);
  return cents;
}

function quantity(value: unknown, label: string): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n) || n <= 0 || n >= 100_000_000_000 || Math.abs(n * 1000 - Math.round(n * 1000)) > 0.00001) {
    throw new Error(`Jumlah ${label} pada laporan tidak valid.`);
  }
  return Math.round(n * 1000) / 1000;
}

function decimalText(value: number, scale: number): string {
  return value.toFixed(scale).replace(/(?:\.0+|(?<=\.[0-9]*?)0+)$/, "").replace(/\.$/, "");
}

function moneyText(cents: number): string {
  const whole = Math.trunc(cents / 100);
  const fraction = cents % 100;
  return fraction ? `${whole}.${String(fraction).padStart(2, "0")}` : String(whole);
}

function periodDate(value: string): string {
  const match = value.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$/);
  if (!match) throw new Error("Periode laporan tidak terbaca.");
  const [, day, month, yearRaw] = match;
  const year = yearRaw.length === 2 ? 2000 + Number(yearRaw) : Number(yearRaw);
  const date = new Date(Date.UTC(year, Number(month) - 1, Number(day)));
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== Number(month) - 1 || date.getUTCDate() !== Number(day)) {
    throw new Error("Tanggal periode laporan tidak valid.");
  }
  return `${year}-${String(Number(month)).padStart(2, "0")}-${String(Number(day)).padStart(2, "0")}`;
}

function excelTimestamp(value: unknown): string {
  if (typeof value !== "number") throw new Error("Waktu transaksi pada laporan tidak valid.");
  const parts = XLSX.SSF.parse_date_code(value);
  if (!parts || parts.y < 2000 || parts.y > 2099) throw new Error("Waktu transaksi pada laporan tidak valid.");
  // iPos stores Excel wall time. Quena business timestamps use Asia/Jakarta (UTC+7).
  return new Date(Date.UTC(parts.y, parts.m - 1, parts.d, parts.H - 7, parts.M, parts.S)).toISOString();
}

function isLegacyXlsOrXlsx(bytes: Uint8Array): boolean {
  const zip = bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 0x03 && bytes[3] === 0x04;
  const ole = bytes.length >= 8 && [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1].every((v, i) => bytes[i] === v);
  return zip || ole;
}

export function parseIposSalesWorkbook(input: Uint8Array): ParsedIposSalesWorkbook {
  if (!input.byteLength || input.byteLength > MAX_FILE_BYTES || !isLegacyXlsOrXlsx(input)) {
    throw new Error("File harus berupa laporan Excel iPos yang valid dan berukuran maksimal 25 MiB.");
  }
  let workbook: XLSX.WorkBook;
  try { workbook = XLSX.read(input, { type: "array", raw: true, cellDates: false, cellFormula: true }); }
  catch { throw new Error("Laporan Excel iPos tidak dapat dibaca."); }
  if (workbook.SheetNames.length !== 1 || workbook.SheetNames[0] !== "Sheet") throw new Error("Laporan harus memiliki satu sheet bernama 'Sheet'.");
  const sheet = workbook.Sheets.Sheet;
  if (cell(sheet, 1, 5) !== "LAPORAN PENJUALAN DETAIL") throw new Error("Judul laporan bukan 'LAPORAN PENJUALAN DETAIL'.");
  if (Object.entries(sheet).some(([address, value]) => !address.startsWith("!") && Boolean(value?.f))) {
    throw new Error("Laporan berisi formula; ekspor ulang laporan sebagai nilai tersimpan dari iPos.");
  }
  if (sheet["!rows"]?.some((row) => row?.hidden)) throw new Error("Laporan memiliki baris tersembunyi dan perlu diekspor ulang dari iPos.");
  const period = String(cell(sheet, 1, 21) ?? "").match(/PERIODE\s*:\s*(\d{1,2}\/\d{1,2}\/\d{2,4})\s*-\s*(\d{1,2}\/\d{1,2}\/\d{2,4})/i);
  if (!period) throw new Error("Rentang periode laporan tidak ditemukan.");
  const reportFrom = periodDate(period[1]);
  const reportTo = periodDate(period[2]);
  if (reportTo < reportFrom) throw new Error("Rentang periode laporan tidak valid.");
  const range = sheet["!ref"] ? XLSX.utils.decode_range(sheet["!ref"]) : null;
  if (!range || range.e.r >= 100_000 || range.e.c >= 128) throw new Error("Struktur laporan melebihi batas yang didukung.");

  const starts: number[] = [];
  for (let r = 0; r <= range.e.r; r += 1) {
    const tx = cell(sheet, r, 1);
    if (typeof tx === "string" && TX_NUMBER.test(tx)) starts.push(r);
  }
  if (!starts.length || starts.length > 10_000) throw new Error("Tidak ditemukan transaksi penjualan pada laporan.");

  const transactions: IposSalesTransaction[] = [];
  const allSkus = new Set<string>();
  const differences: ParsedIposSalesWorkbook["reconciliation"]["differences"] = [];
  let totalQuantity = 0;
  let totalDetailCents = 0;
  let totalTransactionCents = 0;
  let saleLineCount = 0;
  const addDifference = (key: string, expected: number, actual: number, scale: number) => {
    if (Math.abs(expected - actual) > (scale === 3 ? 0.0005 : 0.005)) {
      differences.push({ key, expected: decimalText(expected, scale), actual: decimalText(actual, scale), difference: decimalText(actual - expected, scale) });
    }
  };

  for (let n = 0; n < starts.length; n += 1) {
    const start = starts[n];
    const end = starts[n + 1] ?? range.e.r + 1;
    const sourceTransactionNumber = String(cell(sheet, start, 1));
    const sourceOccurredAt = excelTimestamp(cell(sheet, start, 7));
    const occurredDate = new Date(new Date(sourceOccurredAt).getTime() + 7 * 60 * 60 * 1000).toISOString().slice(0, 10);
    if (occurredDate < reportFrom || occurredDate > reportTo) throw new Error(`Tanggal transaksi ${sourceTransactionNumber} berada di luar periode laporan.`);
    const lines: IposSalesLine[] = [];
    let transactionQty = 0;
    let transactionCents = 0;
    for (let r = start + 1; r < end; r += 1) {
      const lineNo = cell(sheet, r, 1);
      const sku = cell(sheet, r, 2);
      if (!(typeof lineNo === "number" && typeof sku === "string" && sku.trim())) continue;
      const rawQuantity = quantity(cell(sheet, r, 17), `baris ${r + 1}`);
      const rawUnitPrice = amount(cell(sheet, r, 24), `harga baris ${r + 1}`);
      const rawLineCents = amount(cell(sheet, r, 29), `total baris ${r + 1}`);
      const discount = amount(cell(sheet, r, 25), `diskon baris ${r + 1}`);
      if (discount > 10000) throw new Error(`Persentase diskon baris ${r + 1} melebihi 100%.`);
      const expectedLineCents = Math.round(rawQuantity * rawUnitPrice * (10000 - discount) / 10000);
      addDifference(`baris_${r + 1}_detail_vs_harga`, expectedLineCents, rawLineCents, 2);
      const rawItemName = cell(sheet, r, 7);
      if (typeof rawItemName !== "string" || !rawItemName.trim()) throw new Error(`Nama barang baris ${r + 1} kosong.`);
      const rawUnit = cell(sheet, r, 19);
      const line: IposSalesLine = {
        sourceRowNumber: r + 1,
        rawSku: sku.trim(),
        rawItemName,
        rawQuantity: decimalText(rawQuantity, 3),
        rawUnit: typeof rawUnit === "string" && rawUnit.trim() ? rawUnit.trim() : null,
        rawUnitPrice: moneyText(rawUnitPrice),
        rawDiscountPercent: decimalText(Number(cell(sheet, r, 25)), 2),
        rawLineTotal: moneyText(rawLineCents),
      };
      lines.push(line);
      transactionQty += rawQuantity;
      transactionCents += rawLineCents;
      allSkus.add(sku.trim());
      saleLineCount += 1;
    }
    if (!lines.length) throw new Error(`Transaksi ${sourceTransactionNumber} tidak memiliki baris barang.`);

    let totalLabelRow = -1;
    for (let r = start + 1; r < end; r += 1) if (cell(sheet, r, 23) === "Total Akhir :") {
      if (totalLabelRow !== -1) throw new Error(`Total transaksi ${sourceTransactionNumber} muncul lebih dari sekali.`);
      totalLabelRow = r;
    }
    if (totalLabelRow < 0) throw new Error(`Total transaksi ${sourceTransactionNumber} tidak ditemukan.`);
    // In this workbook export the numeric amount is commonly on the row above the label.
    let transactionTotal: number | null = null;
    for (const r of [totalLabelRow, totalLabelRow - 1, totalLabelRow + 1]) {
      const candidate = cell(sheet, r, 28);
      if (typeof candidate === "number") { transactionTotal = amount(candidate, `total transaksi ${sourceTransactionNumber}`); break; }
    }
    if (transactionTotal === null) throw new Error(`Nilai total transaksi ${sourceTransactionNumber} tidak ditemukan.`);
    const findLabeledAmount = (label: string, labelColumn: number, amountColumn: number) => {
      for (let r = start + 1; r < end; r += 1) if (cell(sheet, r, labelColumn) === label) {
        for (const candidateRow of [r, r - 1, r + 1]) {
          const candidate = cell(sheet, candidateRow, amountColumn);
          if (typeof candidate === "number") return amount(candidate, label);
        }
        return 0;
      }
      return 0;
    };
    const discount = findLabeledAmount("Pot. :", 1, 3);
    const tax = findLabeledAmount("Pajak :", 8, 11);
    const fee = findLabeledAmount("Biaya :", 15, 18);
    const totalExpected = transactionCents - discount + tax + fee;
    addDifference(`transaksi_${sourceTransactionNumber}_detail_vs_total`, totalExpected, transactionTotal, 2);
    const subtotalRow = Array.from({ length: end - start - 1 }, (_, i) => start + 1 + i)
      .find((r) => typeof cell(sheet, r, 17) === "number" && typeof cell(sheet, r, 29) === "number"
        && cell(sheet, r, 1) === null && cell(sheet, r, 2) === null);
    if (subtotalRow !== undefined) {
      addDifference(`transaksi_${sourceTransactionNumber}_qty_subtotal`, transactionQty, quantity(cell(sheet, subtotalRow, 17), `subtotal transaksi ${sourceTransactionNumber}`), 3);
      addDifference(`transaksi_${sourceTransactionNumber}_line_subtotal`, transactionCents, amount(cell(sheet, subtotalRow, 29), `subtotal transaksi ${sourceTransactionNumber}`), 2);
    }
    totalQuantity += transactionQty;
    totalDetailCents += transactionCents;
    totalTransactionCents += transactionTotal;
    transactions.push({ sourceRowNumber: start + 1, sourceTransactionNumber, sourceOccurredAt, lines,
      detailQuantity: decimalText(transactionQty, 3), detailAmount: moneyText(transactionCents),
      sourceTransactionTotal: moneyText(transactionTotal), sourceDiscountTotal: moneyText(discount),
      sourceTaxTotal: moneyText(tax), sourceFeeTotal: moneyText(fee) });
  }

  const footerRows = Array.from({ length: range.e.r + 1 }, (_, r) => r).filter((r) => cell(sheet, r, 22) === "Jumlah Item :");
  if (footerRows.length !== 1) throw new Error("Footer total laporan tidak ditemukan atau ganda.");
  const footerRow = footerRows[0];
  const footer = {
    quantity: decimalText(quantity(cell(sheet, footerRow, 26), "footer jumlah item"), 3),
    subtotal: moneyText(amount(cell(sheet, footerRow + 1, 26), "footer subtotal")),
    discount: moneyText(amount(cell(sheet, footerRow + 2, 26), "footer potongan")),
    tax: moneyText(amount(cell(sheet, footerRow + 3, 26), "footer pajak")),
    fee: moneyText(amount(cell(sheet, footerRow + 4, 26), "footer biaya")),
    grandTotal: moneyText(amount(cell(sheet, footerRow + 5, 26), "footer total akhir")),
  };
  const footerQty = Number(footer.quantity);
  const footerSubtotal = Number(footer.subtotal);
  const footerGrand = Number(footer.grandTotal);
  addDifference("detail_vs_footer_quantity", totalQuantity, footerQty, 3);
  addDifference("detail_vs_footer_subtotal", totalDetailCents, Math.round(footerSubtotal * 100), 2);
  addDifference("transaction_total_vs_footer", totalTransactionCents, Math.round(footerGrand * 100), 2);
  addDifference("detail_vs_transaction_total", totalDetailCents, totalTransactionCents, 2);

  const byTime = transactions.map((t) => t.sourceOccurredAt).sort();
  return {
    sheetName: "Sheet", reportFrom, reportTo, transactions, footer,
    reconciliation: { detailQuantity: decimalText(totalQuantity, 3), footerQuantity: footer.quantity,
      detailAmount: moneyText(totalDetailCents), transactionTotal: moneyText(totalTransactionCents),
      footerSubtotal: footer.subtotal, footerGrandTotal: footer.grandTotal,
      isReconciled: differences.length === 0, differences },
    summary: { transactionCount: transactions.length, saleLineCount, totalQuantity: decimalText(totalQuantity, 3),
      totalAmount: moneyText(totalTransactionCents), uniqueSkuCount: allSkus.size,
      firstOccurredAt: byTime[0], lastOccurredAt: byTime.at(-1)! },
  };
}
