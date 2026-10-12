"use client";

import { useState } from "react";
import { PosReceipt, type PosReceiptData } from "@/components/pos/pos-receipt";
import styles from "@/components/sales/sales-history.module.css";

export function ReceiptReprint({ receipt }: { receipt: PosReceiptData }) {
  const [size, setSize] = useState<"58" | "80">("80");
  return <>
    <div className="pos-receipt-toolbar">
      <label>Ukuran struk
        <select value={size} onChange={(event) => setSize(event.target.value as "58" | "80")}>
          <option value="58">58 mm</option><option value="80">80 mm</option>
        </select>
      </label>
      <button className={styles.primary} type="button" onClick={() => window.print()}>Cetak Ulang Struk</button>
    </div>
    <div className="pos-receipt-preview"><PosReceipt receipt={receipt} size={size} /></div>
    <div className="pos-print-root"><PosReceipt receipt={receipt} size={size} /></div>
  </>;
}
