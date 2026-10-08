"use client";

import { createContext, useContext } from "react";
import type { ReceiptInvoiceLine } from "@/lib/purchasing/receipt-model";

export type ReceiptFinanceContextValue = {
  lines: ReceiptInvoiceLine[];
  setLines: (next: ReceiptInvoiceLine[] | ((current: ReceiptInvoiceLine[]) => ReceiptInvoiceLine[])) => void;
  notaUnavailable: boolean;
  setNotaUnavailable: (value: boolean) => void;
  saveInvoiceDraft: () => Promise<string | null>;
  registerInvoiceDraftSaver: (save: (() => Promise<string | null>) | null) => void;
};

export const ReceiptFinanceContext = createContext<ReceiptFinanceContextValue | null>(null);
export function useReceiptFinance() { return useContext(ReceiptFinanceContext); }
