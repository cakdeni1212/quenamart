"use client";

import { useState } from "react";
import styles from "./digital-receipt-actions.module.css";

export function DigitalReceiptActions() {
  const [notice, setNotice] = useState("");
  const share = async () => {
    const url = window.location.href;
    if (navigator.share) {
      try { await navigator.share({ title: "Struk Digital Quena Mart", url }); }
      catch { /* Customer may dismiss the native share sheet. */ }
      return;
    }
    try {
      if (!navigator.clipboard) throw new Error("clipboard-unavailable");
      await navigator.clipboard.writeText(url);
      setNotice("Tautan struk disalin.");
    } catch { setNotice("Tautan tidak dapat dibagikan dari browser ini."); }
  };
  return <>
    <div className="digital-receipt-actions">
      <button type="button" onClick={() => window.print()}>Cetak / Simpan</button>
      <button type="button" onClick={() => void share()}>Bagikan</button>
    </div>
    {notice && <p className={styles.notice} role="status">{notice}</p>}
  </>;
}
