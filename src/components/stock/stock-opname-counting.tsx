"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type FormEvent } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { applyRecordCountIntent, issueRecordCountIntent, type RecordCountActionResult } from "@/lib/stock/opname-count-action";
import { applyOpnameItemIntent, issueOpnameItemIntent, type OpnameItemActionResult, type OpnameItemOperation } from "@/lib/stock/opname-item-action";
import { applyStockOpnameLifecycleIntent, issueStockOpnameLifecycleIntent, type StockOpnameLifecycleActionResult } from "@/lib/stock/opname-lifecycle-action";
import { canRetryStockOpnameLifecycle, hasSessionLifecycleInFlight, isSubmitReviewAdvisoryEligible, lifecycleOperationLabel, removeSessionEntries, removeSessionOperationEntry, stockOpnameLifecycleRequestKey, stockOpnameLifecycleStateKey, STOCK_OPNAME_LIFECYCLE_OPERATIONS } from "@/lib/stock/opname-lifecycle-model";
import { transitionItemEditorAfterApply, STOCK_OPNAME_COUNT_FILTERS, STOCK_OPNAME_COUNT_PAGE_SIZE, type OpnameItemEditorState, type StockOpnameCountFilter } from "@/lib/stock/opname-count-model";
import type { StockOpnameCountData } from "@/lib/stock/opname-count-read";

const FILTER_LABEL: Record<StockOpnameCountFilter, string> = {
  ALL: "Semua",
  UNCOUNTED: "Belum dihitung",
  COUNTED: "Sudah dihitung",
  RECOUNT: "Perlu hitung ulang",
};

type BarcodeResult = {
  resolution: "BARCODE_NOT_FOUND" | "BARCODE_MATCH" | "BARCODE_AMBIGUOUS";
  product_id: string | null;
  sku: string | null;
  product_name: string | null;
  barcode_id: string | null;
};

type PendingRequest =
  | { requestId: string; operation: "RECORD_COUNT"; quantity: string }
  | { requestId: string; operation: "REBASE_ITEM" | "REVIEW_EXCEPTION" };
type ItemActionResult = RecordCountActionResult | OpnameItemActionResult;
type PendingLifecycle = { sessionId: string; operation: (typeof STOCK_OPNAME_LIFECYCLE_OPERATIONS)[number]; requestId: string };
type LifecycleFeedback = { sessionId: string; operation: PendingLifecycle["operation"]; result: StockOpnameLifecycleActionResult };

function countFormat(value: number | string | null) {
  if (value === null) return "—";
  return new Intl.NumberFormat("id-ID", { maximumFractionDigits: 3 }).format(Number(value));
}

function hrefFor(pathname: string, q: string, filter: StockOpnameCountFilter, page: number) {
  const params = new URLSearchParams();
  if (q) params.set("q", q);
  if (filter !== "ALL") params.set("filter", filter);
  if (page > 1) params.set("page", String(page));
  const suffix = params.toString();
  return suffix ? `${pathname}?${suffix}` : pathname;
}

function pendingKey(sessionId: string, productId: string) {
  return `quena-opname-count:${sessionId}:${productId}`;
}

function loadPendingValue(key: string): string | null {
  try { return window.sessionStorage.getItem(key); } catch { return null; }
}

function savePendingValue(key: string, value: string): boolean {
  try { window.sessionStorage.setItem(key, value); return true; } catch { return false; }
}

function removePendingValue(key: string) {
  try { window.sessionStorage.removeItem(key); } catch { /* replay remains safe if storage cannot be cleared */ }
}

function loadPendingLifecycle(sessionId: string): Map<PendingLifecycle["operation"], PendingLifecycle> {
  const restored = new Map<PendingLifecycle["operation"], PendingLifecycle>();
  for (const operation of STOCK_OPNAME_LIFECYCLE_OPERATIONS) {
    try {
      const raw = window.sessionStorage.getItem(stockOpnameLifecycleRequestKey(sessionId, operation));
      if (!raw) continue;
      const value = JSON.parse(raw) as Partial<PendingLifecycle>;
      if (value.sessionId === sessionId && value.operation === operation && typeof value.requestId === "string") {
        restored.set(operation, { sessionId, operation, requestId: value.requestId });
      }
    } catch { /* a missing browser storage value does not block session reads */ }
  }
  return restored;
}

export function StockOpnameCounting({ data }: { data: StockOpnameCountData }) {
  const router = useRouter();
  const pathname = usePathname();
  const supabase = useMemo(() => createClient(), []);
  const [barcode, setBarcode] = useState("");
  const [scanNotice, setScanNotice] = useState<string | null>(null);
  const [scanError, setScanError] = useState(false);
  const [focusedProduct, setFocusedProduct] = useState<string | null>(null);
  const [scannedBarcodeByProduct, setScannedBarcodeByProduct] = useState<Map<string, string>>(() => new Map());
  const [itemEditor, setItemEditor] = useState<OpnameItemEditorState>({
    editingProduct: null,
    quantityDraft: "",
    exceptionProduct: null,
    exceptionReasonDraft: "",
  });
  const [pendingByProduct, setPendingByProduct] = useState<Map<string, PendingRequest>>(() => new Map());
  const [busyProduct, setBusyProduct] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<{ productId: string; result: ItemActionResult } | null>(null);
  const [pendingLifecycle, setPendingLifecycle] = useState<Map<string, PendingLifecycle>>(() => new Map());
  const [lifecycleReadySessionId, setLifecycleReadySessionId] = useState<string | null>(null);
  const [lifecycleBusy, setLifecycleBusy] = useState<Map<string, PendingLifecycle["operation"]>>(() => new Map());
  const [lifecycleFeedback, setLifecycleFeedback] = useState<Map<string, LifecycleFeedback>>(() => new Map());
  const lifecycleInFlight = useRef(new Set<string>());
  const currentSessionIdRef = useRef(data.session?.id ?? null);
  const backHref = "/stok/opname";

  useLayoutEffect(() => {
    currentSessionIdRef.current = data.session?.id ?? null;
  }, [data.session?.id]);

  useEffect(() => {
    if (!data.session) return;
    const timer = window.setTimeout(() => {
      const restored = new Map<string, PendingRequest>();
      for (const item of data.items) {
        const storageKey = pendingKey(data.session!.id, item.productId);
        const raw = loadPendingValue(storageKey);
        if (!raw) continue;
        try {
          const parsed = JSON.parse(raw) as Partial<PendingRequest> & { quantity?: unknown };
          if (typeof parsed.requestId !== "string") continue;
          if (parsed.operation === "RECORD_COUNT" && typeof parsed.quantity === "string") {
            restored.set(item.productId, { requestId: parsed.requestId, operation: "RECORD_COUNT", quantity: parsed.quantity });
          } else if (parsed.operation === "REBASE_ITEM" || parsed.operation === "REVIEW_EXCEPTION") {
            restored.set(item.productId, { requestId: parsed.requestId, operation: parsed.operation });
          } else if (typeof parsed.quantity === "string") {
            // Recover the previous Checkpoint 3 storage shape without issuing a new request.
            restored.set(item.productId, { requestId: parsed.requestId, operation: "RECORD_COUNT", quantity: parsed.quantity });
          }
        } catch {
          removePendingValue(storageKey);
        }
      }
      setPendingByProduct(restored);
    }, 0);
    return () => window.clearTimeout(timer);
  }, [data.items, data.session]);

  useEffect(() => {
    const sessionId = data.session?.id;
    if (!sessionId) return;
    const timer = window.setTimeout(() => {
      const restored = loadPendingLifecycle(sessionId);
      setPendingLifecycle((current) => {
        const next = new Map(current);
        for (const [key, pending] of next) if (pending.sessionId === sessionId) next.delete(key);
        for (const pending of restored.values()) {
          next.set(stockOpnameLifecycleStateKey(pending.sessionId, pending.operation), pending);
        }
        return next;
      });
      setLifecycleReadySessionId(sessionId);
    }, 0);
    return () => window.clearTimeout(timer);
  }, [data.session?.id]);

  useEffect(() => {
    if (!focusedProduct) return;
    const item = data.items.find((row) => row.productId === focusedProduct);
    if (!item) return;
    requestAnimationFrame(() => {
      setItemEditor((current) => ({
        ...current,
        editingProduct: item.productId,
        quantityDraft: item.physicalQuantity === null ? "" : String(item.physicalQuantity),
      }));
      document.getElementById(`opname-item-${item.productId}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
      setFocusedProduct(null);
    });
  }, [data.items, focusedProduct]);

  const finishApply = useCallback(async (productId: string, pending: PendingRequest) => {
    setBusyProduct(productId);
    let result: ItemActionResult;
    try {
      result = pending.operation === "RECORD_COUNT"
        ? await applyRecordCountIntent(pending.requestId)
        : await applyOpnameItemIntent(pending.requestId, pending.operation);
    } catch {
      result = { kind: "error", requestId: pending.requestId, message: "Respons belum diterima. Ulangi permintaan tersimpan dengan tombol yang sama." };
    }
    setFeedback({ productId, result });
    setBusyProduct(null);
    setItemEditor((current) => transitionItemEditorAfterApply(
      current,
      productId,
      pending.operation,
      result.kind === "success",
    ));
    if (result.kind === "success" || result.kind === "stale-item" || result.kind === "stale-baseline") {
      if (data.session) removePendingValue(pendingKey(data.session.id, productId));
      setPendingByProduct((current) => {
        const next = new Map(current);
        next.delete(productId);
        return next;
      });
      if (result.kind === "success") {
        setScannedBarcodeByProduct((current) => {
          const next = new Map(current);
          next.delete(productId);
          return next;
        });
      }
      router.refresh();
    }
  }, [data.session, router]);

  const applyLifecycleRequest = useCallback(async (pending: PendingLifecycle) => {
    const stateKey = stockOpnameLifecycleStateKey(pending.sessionId, pending.operation);
    let result: StockOpnameLifecycleActionResult;
    try {
      result = await applyStockOpnameLifecycleIntent({ operation: pending.operation, requestId: pending.requestId });
    } catch {
      result = { kind: "error", requestId: pending.requestId, message: "Hasil belum terkonfirmasi. Ulangi tindakan tersimpan dengan tombol retry." };
    }
    setLifecycleFeedback((current) => new Map(current).set(stateKey, { ...pending, result }));
    if (result.kind === "success" || result.kind === "rejected") {
      removePendingValue(stockOpnameLifecycleRequestKey(pending.sessionId, pending.operation));
      setPendingLifecycle((current) => removeSessionOperationEntry(current, pending.sessionId, pending.operation));
      if (currentSessionIdRef.current === pending.sessionId) router.refresh();
    }
  }, [router]);

  async function startLifecycleOperation(operation: PendingLifecycle["operation"]) {
    const session = data.session;
    const sessionPending = session && [...pendingLifecycle.values()].some((pending) =>
      pending.sessionId === session.id && canRetryStockOpnameLifecycle(pending.operation, session.status));
    if (!session || !lifecycleReady || hasSessionLifecycleInFlight(lifecycleInFlight.current, session.id) || sessionPending) return;
    if (operation === "SUBMIT_REVIEW" && !isSubmitReviewAdvisoryEligible(data.progress)) return;
    if (operation === "CANCEL_SESSION" && !window.confirm(
      "Batalkan sesi opname ini? Sesi akan menjadi baca-saja. Riwayat tetap tersimpan dan tidak ada penyesuaian stok yang diposting."
    )) return;

    const stateKey = stockOpnameLifecycleStateKey(session.id, operation);
    lifecycleInFlight.current.add(stateKey);
    setLifecycleBusy((current) => new Map(current).set(stateKey, operation));
    setLifecycleFeedback((current) => removeSessionEntries(current, session.id));
    try {
      let issued: StockOpnameLifecycleActionResult;
      try {
        issued = await issueStockOpnameLifecycleIntent({ operation, sessionId: session.id });
      } catch {
        setLifecycleFeedback((current) => new Map(current).set(
          stockOpnameLifecycleStateKey(session.id, operation),
          { sessionId: session.id, operation, result: { kind: "error", message: "Permintaan belum terkonfirmasi. Coba lagi dengan operasi dan sesi yang sama." } },
        ));
        return;
      }
      if (issued.kind !== "issued" || !issued.requestId) {
        setLifecycleFeedback((current) => new Map(current).set(
          stockOpnameLifecycleStateKey(session.id, operation),
          { sessionId: session.id, operation, result: issued },
        ));
        return;
      }
      const pending: PendingLifecycle = { sessionId: session.id, operation, requestId: issued.requestId };
      if (!savePendingValue(stockOpnameLifecycleRequestKey(session.id, operation), JSON.stringify(pending))) {
        setLifecycleFeedback((current) => new Map(current).set(
          stockOpnameLifecycleStateKey(session.id, operation),
          { ...pending, result: { kind: "error", requestId: issued.requestId, message: "Browser tidak dapat menyimpan ID permintaan untuk retry aman. Aktifkan penyimpanan sesi browser lalu coba lagi." } },
        ));
        return;
      }
      setPendingLifecycle((current) => new Map(current).set(stockOpnameLifecycleStateKey(session.id, operation), pending));
      await applyLifecycleRequest(pending);
    } finally {
      lifecycleInFlight.current.delete(stateKey);
      setLifecycleBusy((current) => {
        const next = new Map(current);
        next.delete(stateKey);
        return next;
      });
    }
  }

  async function retryLifecycleRequest(pending: PendingLifecycle) {
    if (!data.session || pending.sessionId !== data.session.id
        || hasSessionLifecycleInFlight(lifecycleInFlight.current, pending.sessionId)
        || !canRetryStockOpnameLifecycle(pending.operation, data.session.status)) return;
    const stateKey = stockOpnameLifecycleStateKey(pending.sessionId, pending.operation);
    lifecycleInFlight.current.add(stateKey);
    setLifecycleBusy((current) => new Map(current).set(stateKey, pending.operation));
    setLifecycleFeedback((current) => removeSessionOperationEntry(current, pending.sessionId, pending.operation));
    try {
      await applyLifecycleRequest(pending);
    } finally {
      lifecycleInFlight.current.delete(stateKey);
      setLifecycleBusy((current) => {
        const next = new Map(current);
        next.delete(stateKey);
        return next;
      });
    }
  }

  async function saveCount(item: StockOpnameCountData["items"][number]) {
    if (!data.session) return;
    setFeedback(null);
    setBusyProduct(item.productId);
    const input = {
      sessionId: data.session.id,
      productId: item.productId,
      physicalQuantity: itemEditor.quantityDraft,
      expectedRevision: item.revision,
      barcodeId: scannedBarcodeByProduct.get(item.productId) ?? null,
    };
    let issued: RecordCountActionResult;
    try {
      issued = await issueRecordCountIntent(input);
    } catch {
      setFeedback({ productId: item.productId, result: { kind: "error", message: "Permintaan belum dapat dikonfirmasi. Kirim ulang nilai yang sama untuk melanjutkan." } });
      setBusyProduct(null);
      return;
    }
    if (issued.kind !== "issued" || !issued.requestId) {
      setFeedback({ productId: item.productId, result: issued });
      setBusyProduct(null);
      return;
    }
    const pending: PendingRequest = { requestId: issued.requestId, operation: "RECORD_COUNT", quantity: itemEditor.quantityDraft };
    if (!savePendingValue(pendingKey(data.session.id, item.productId), JSON.stringify(pending))) {
      setFeedback({ productId: item.productId, result: { kind: "error", requestId: issued.requestId, message: "Browser tidak dapat menyimpan ID permintaan untuk retry aman. Aktifkan penyimpanan sesi browser lalu kirim ulang nilai yang sama." } });
      setBusyProduct(null);
      return;
    }
    setPendingByProduct((current) => new Map(current).set(item.productId, pending));
    setBusyProduct(null);
    await finishApply(item.productId, pending);
  }

  async function submitItemOperation(
    operation: OpnameItemOperation,
    item: StockOpnameCountData["items"][number],
    reason?: string,
  ) {
    if (!data.session || !canCount || pendingByProduct.has(item.productId) || item.requiresRecount && operation === "REVIEW_EXCEPTION") return;
    setFeedback(null);
    setBusyProduct(item.productId);
    const issued = await issueOpnameItemIntent({
      operation,
      sessionId: data.session.id,
      productId: item.productId,
      expectedRevision: item.revision,
      ...(operation === "REVIEW_EXCEPTION" ? { reason } : {}),
    }).catch(() => ({ kind: "error", message: "Permintaan belum dapat dikonfirmasi. Coba lagi dengan tindakan yang sama." } as OpnameItemActionResult));
    if (issued.kind !== "issued" || !issued.requestId) {
      setFeedback({ productId: item.productId, result: issued });
      setBusyProduct(null);
      return;
    }
    const pending: PendingRequest = { requestId: issued.requestId, operation };
    if (!savePendingValue(pendingKey(data.session.id, item.productId), JSON.stringify(pending))) {
      setFeedback({ productId: item.productId, result: { kind: "error", requestId: issued.requestId, message: "Browser tidak dapat menyimpan ID permintaan untuk retry aman. Aktifkan penyimpanan sesi browser lalu coba lagi." } });
      setBusyProduct(null);
      return;
    }
    setPendingByProduct((current) => new Map(current).set(item.productId, pending));
    setBusyProduct(null);
    await finishApply(item.productId, pending);
  }

  async function scanBarcode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = barcode.trim();
    if (!data.session || !value) return;
    setScanNotice(null);
    setScanError(false);
    const { data: rows, error } = await supabase.rpc("resolve_stock_barcode", {
      p_outlet_id: data.session.outletId,
      p_barcode: value,
    });
    if (error) {
      console.error("[stock-opname-count] barcode resolver failed", {
        operation: "resolve_stock_barcode",
        code: error.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
        message: error.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      });
      setScanNotice("Barcode belum dapat diperiksa. Coba lagi.");
      setScanError(true);
      return;
    }
    const match = ((rows ?? []) as BarcodeResult[])[0];
    if (!match || match.resolution === "BARCODE_NOT_FOUND") {
      setScanNotice("Barcode belum terdaftar");
      return;
    }
    if (match.resolution === "BARCODE_AMBIGUOUS") {
      setScanNotice("Barcode terhubung ke beberapa produk. Pemilihan otomatis diblokir.");
      setScanError(true);
      return;
    }
    if (!match.product_id || !match.sku || !match.barcode_id) {
      setScanNotice("Produk tidak dapat dipastikan dari barcode ini.");
      setScanError(true);
      return;
    }
    const { data: item, error: itemError } = await supabase.from("stock_opname_items")
      .select("product_id").eq("session_id", data.session.id).eq("product_id", match.product_id).maybeSingle();
    if (itemError) {
      console.error("[stock-opname-count] session item lookup failed", {
        operation: "stock_opname_item_barcode_membership",
        code: itemError.code?.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 80),
        message: itemError.message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240),
      });
      setScanNotice("Item opname belum dapat diperiksa. Coba lagi.");
      setScanError(true);
      return;
    }
    if (!item) {
      setScanNotice("Produk ini tidak termasuk dalam sesi opname.");
      setScanError(true);
      return;
    }
    setScannedBarcodeByProduct((current) => new Map(current).set(match.product_id!, match.barcode_id!));
    setFocusedProduct(match.product_id);
    setScanNotice("Produk ditemukan. Periksa item dan simpan jumlah fisik secara manual.");
    setBarcode("");
    const target = hrefFor(pathname, match.sku, "ALL", 1);
    router.replace(target);
  }

  const progressPercent = data.progress?.total ? Math.round((data.progress.accounted / data.progress.total) * 100) : 0;
  const canCount = data.session?.status === "COUNTING";
  const canReviewLifecycle = data.session?.status === "REVIEW";
  const lifecycleReady = !data.session || lifecycleReadySessionId === data.session.id;
  const currentLifecycleRequests = data.session
    ? [...pendingLifecycle.values()].filter((pending) => pending.sessionId === data.session!.id)
    : [];
  const currentRetryableLifecycleRequests = data.session
    ? currentLifecycleRequests.filter((pending) => canRetryStockOpnameLifecycle(pending.operation, data.session!.status))
    : [];
  const currentLifecycleFeedback = data.session
    ? [...lifecycleFeedback.values()].filter((feedback) => feedback.sessionId === data.session!.id)
    : [];
  const currentLifecycleBusy = data.session
    ? [...lifecycleBusy.entries()].find(([key]) => key.startsWith(`${data.session!.id}:`))?.[1] ?? null
    : null;
  const lifecycleActionDisabled = !lifecycleReady || currentLifecycleBusy !== null || currentRetryableLifecycleRequests.length > 0;

  return <div className="stock-opname-counting">
    <Link className="stock-opname-back" href={backHref}>← Kembali ke daftar opname</Link>
    {data.error ? <div className="surface-card product-state product-error" role="alert"><strong>Ruang hitung belum dapat dimuat.</strong><span>{data.error}</span></div> : !data.session ? null : <>
      <div className="eyebrow">PERSEDIAAN OUTLET · PENCATATAN FISIK</div>
      <div className="page-heading stock-opname-heading">
        <div><h1>Opname #{data.session.id.slice(0, 8).toUpperCase()}</h1><p>{data.session.outletName} · {data.session.scope === "FULL" ? "Opname penuh" : "Opname sebagian"}</p></div>
        <span className={`stock-opname-status stock-opname-status-${data.session.status.toLowerCase()}`}>{data.session.status === "COUNTING" ? "Menghitung" : data.session.status === "REVIEW" ? "Sedang direview" : data.session.status === "POSTED" ? "Selesai" : "Dibatalkan"}</span>
      </div>

      <section className="surface-card stock-opname-progress" aria-label="Progress opname">
        {data.progress ? <>
          <div className="stock-opname-progress-numbers">
            <div><strong>{data.progress.total.toLocaleString("id-ID")}</strong><span>total item</span></div>
            <div><strong>{data.progress.counted.toLocaleString("id-ID")}</strong><span>terhitung</span></div>
            <div><strong>{data.progress.exception.toLocaleString("id-ID")}</strong><span>pengecualian</span></div>
            <div><strong>{data.progress.accounted.toLocaleString("id-ID")}</strong><span>terdata</span></div>
            <div><strong>{data.progress.remaining.toLocaleString("id-ID")}</strong><span>tersisa</span></div>
            <div><strong>{data.progress.recountRequired.toLocaleString("id-ID")}</strong><span>perlu hitung ulang</span></div>
          </div>
          <div className="stock-opname-progress-track" role="progressbar" aria-valuenow={progressPercent} aria-valuemin={0} aria-valuemax={100}><span style={{ width: `${progressPercent}%` }} /></div>
          <p className="stock-opname-progress-note">Terdata mencakup hitungan fisik dan pengecualian yang ditinjau. Item yang perlu hitung ulang tidak dihitung sebagai selesai.</p>
        </> : <p className="stock-opname-warning" role="status">{data.progressError ?? "Progress belum tersedia."}</p>}
        {data.progressError && data.progress && <p className="stock-opname-warning" role="status">{data.progressError}</p>}
      </section>

      {canCount && <section className="surface-card stock-opname-lifecycle" aria-label="Kirim opname untuk review">
        <div><strong>Kelengkapan opname</strong><p>{!data.progress ? "Ringkasan kelengkapan belum tersedia." : isSubmitReviewAdvisoryEligible(data.progress) ? "Semua item sudah dihitung atau diberi pengecualian." : "Masih ada item yang belum selesai dihitung atau perlu hitung ulang."}</p><small>Database memeriksa ulang kelengkapan saat dikirim. Ringkasan ini tidak memeriksa perubahan stok sejak hitungan.</small></div>
        <button type="button" disabled={!isSubmitReviewAdvisoryEligible(data.progress) || lifecycleActionDisabled}
          onClick={() => void startLifecycleOperation("SUBMIT_REVIEW")}>
          {currentLifecycleBusy === "SUBMIT_REVIEW" ? "Mengirim…" : "Ajukan untuk review"}
        </button>
        {!data.progress && <p className="stock-opname-warning" role="status">Progress belum tersedia; pengajuan review dinonaktifkan sampai ringkasan berhasil dimuat.</p>}
        {data.progress && (data.progress.remaining > 0 || data.progress.recountRequired > 0) && <p className="stock-opname-warning" role="status">Selesaikan item tersisa dan hitung ulang yang diperlukan sebelum mengajukan review.</p>}
        <button type="button" className="stock-opname-cancel-session" disabled={lifecycleActionDisabled}
          onClick={() => void startLifecycleOperation("CANCEL_SESSION")}>{currentLifecycleBusy === "CANCEL_SESSION" ? "Membatalkan…" : "Batalkan sesi"}</button>
      </section>}

      {canReviewLifecycle && <section className="surface-card stock-opname-lifecycle" aria-label="Sesi dalam review">
        <div><strong>Penghitungan telah diajukan untuk ditinjau.</strong><p>Data item bersifat baca-saja selama sesi berada dalam tahap review.</p></div>
        <button type="button" disabled={lifecycleActionDisabled} onClick={() => void startLifecycleOperation("RETURN_TO_COUNTING")}>
          {currentLifecycleBusy === "RETURN_TO_COUNTING" ? "Mengembalikan…" : "Kembali ke penghitungan"}
        </button>
        <button type="button" className="stock-opname-cancel-session" disabled={lifecycleActionDisabled}
          onClick={() => void startLifecycleOperation("CANCEL_SESSION")}>{currentLifecycleBusy === "CANCEL_SESSION" ? "Membatalkan…" : "Batalkan sesi"}</button>
      </section>}

      {data.session.status === "CANCELLED" && <div className="stock-opname-warning" role="status">Sesi dibatalkan dan sekarang baca-saja. Hitungan, pengecualian, dan riwayat tetap tersedia.</div>}
      {data.session.status === "POSTED" && <div className="stock-opname-warning" role="status">Sesi telah selesai dan hanya dapat dilihat.</div>}

      {currentLifecycleRequests.map((pending) => <section className="stock-opname-pending-request" role="status" key={pending.operation}>
        <span>Hasil “{lifecycleOperationLabel(pending.operation)}” belum terkonfirmasi. Retry akan memakai ID permintaan yang sama.</span>
        {data.session && canRetryStockOpnameLifecycle(pending.operation, data.session.status)
          ? <button type="button" className="secondary-button" disabled={currentLifecycleBusy !== null}
            onClick={() => void retryLifecycleRequest(pending)}>{currentLifecycleBusy === pending.operation ? "Memeriksa…" : "Cek ulang hasil tersimpan"}</button>
          : <span>Permintaan tetap tersimpan; retry tidak tersedia pada status sesi saat ini.</span>}
      </section>)}
      {currentLifecycleFeedback.map((feedback) => <p key={stockOpnameLifecycleStateKey(feedback.sessionId, feedback.operation)} className={feedback.result.kind === "error" ? "stock-opname-action-error" : "stock-opname-count-feedback"} role={feedback.result.kind === "error" ? "alert" : "status"}><strong>{lifecycleOperationLabel(feedback.operation)}:</strong> {feedback.result.message}</p>)}

      {canCount && <form className="surface-card stock-opname-scanner" onSubmit={scanBarcode}>
        <label htmlFor="opname-barcode">Pindai barcode lalu tekan Enter</label>
        <div><input id="opname-barcode" value={barcode} onChange={(event) => setBarcode(event.target.value)} autoComplete="off" inputMode="none" /><button type="submit" disabled={!barcode.trim()}>Cari item</button></div>
        <span className={`stock-opname-scan-note${scanError ? " is-error" : ""}`} aria-live="polite">{scanNotice ?? "Pemindaian hanya memilih item; jumlah tidak berubah sampai Anda menyimpan hitungan."}</span>
      </form>}

      <form className="stock-opname-count-search" action={pathname} method="get">
        <label htmlFor="opname-item-q">Cari nama atau SKU</label>
        <div><input id="opname-item-q" name="q" type="search" defaultValue={data.query.q} maxLength={100} placeholder="Nama produk atau SKU" />
          {data.query.filter !== "ALL" && <input type="hidden" name="filter" value={data.query.filter} />}
          <button type="submit">Cari</button></div>
      </form>

      <nav className="stock-opname-filters" aria-label="Filter item opname">
        {STOCK_OPNAME_COUNT_FILTERS.map((filter) => <Link key={filter}
          href={hrefFor(pathname, data.query.q, filter, 1)} aria-current={data.query.filter === filter ? "page" : undefined}
          className={`stock-opname-filter${data.query.filter === filter ? " is-active" : ""}`}>{FILTER_LABEL[filter]}</Link>)}
      </nav>
      <p className="stock-opname-result-note">Menampilkan {data.items.length ? ((data.query.page - 1) * STOCK_OPNAME_COUNT_PAGE_SIZE + 1).toLocaleString("id-ID") : 0}–{((data.query.page - 1) * STOCK_OPNAME_COUNT_PAGE_SIZE + data.items.length).toLocaleString("id-ID")} dari {data.filteredTotal.toLocaleString("id-ID")} item sesuai pencarian/filter.</p>

      {data.items.length === 0 ? <div className="surface-card product-state"><strong>Tidak ada item yang cocok</strong><span>Ubah pencarian atau filter untuk melihat item lain.</span></div> : <ol className="stock-opname-count-list">
        {data.items.map((item) => {
          const pending = pendingByProduct.get(item.productId);
          const result = feedback && feedback.productId === item.productId ? feedback.result : null;
          const isEditing = itemEditor.editingProduct === item.productId;
          const editable = canCount && !item.requiresRecount;
          const isException = item.exceptionReviewed && item.physicalQuantity === null && !item.requiresRecount;
          return <li className="surface-card stock-opname-count-card" id={`opname-item-${item.productId}`} key={item.id}>
            <div className="stock-opname-count-heading"><div><strong>{item.name}</strong><span>{item.sku}{item.barcode ? ` · ${item.barcode}` : ""}{item.rack ? ` · Rak ${item.rack}` : " · Rak kosong"}</span></div>
              <span className={`stock-opname-counted${item.physicalQuantity === null || item.requiresRecount ? " is-pending" : ""}`}>{item.requiresRecount ? "Perlu hitung ulang" : isException ? "Pengecualian ditinjau" : item.physicalQuantity === null ? "Belum dihitung" : "Sudah dihitung"}</span></div>
            <dl className="stock-opname-count-values">
              <div><dt>Saldo saat sesi dibuat</dt><dd>{countFormat(item.baselineQuantity)}</dd></div>
              <div><dt>Hitungan fisik</dt><dd>{countFormat(item.physicalQuantity)}</dd></div>
              <div><dt>Selisih</dt><dd>{countFormat(item.variance)}</dd></div>
              <div><dt>Revisi item</dt><dd>{item.revision}</dd></div>
            </dl>
            {item.requiresRecount && <div className="stock-opname-warning stock-opname-stale-panel"><strong>Saldo stok berubah saat opname berlangsung.</strong><span>Baseline sesi {countFormat(item.baselineQuantity)} sudah tidak berlaku. Hitungan dan pengecualian lama tidak menyelesaikan item ini.</span>
              {canCount && !pending && <button type="button" disabled={busyProduct === item.productId} onClick={() => void submitItemOperation("REBASE_ITEM", item)}>{busyProduct === item.productId ? "Memperbarui…" : "Perbarui baseline & hitung ulang"}</button>}
            </div>}
            {item.exceptionReason && <p className={`stock-opname-exception-note${item.requiresRecount ? " is-stale" : ""}`}>
              {item.requiresRecount ? `Pengecualian sebelumnya (tidak terdata karena perlu hitung ulang): ${item.exceptionReason}` : isException ? `Alasan pengecualian: ${item.exceptionReason}` : `Catatan pengecualian sebelumnya: ${item.exceptionReason}`}
            </p>}
            {pending && <div className="stock-opname-pending-request" role="status"><span>{pending.operation === "RECORD_COUNT" ? `Permintaan hitung ${pending.quantity}` : pending.operation === "REBASE_ITEM" ? "Permintaan pembaruan baseline" : "Permintaan pengecualian"} belum terkonfirmasi.</span>{canCount ? <button type="button" className="secondary-button" disabled={busyProduct === item.productId} onClick={() => void finishApply(item.productId, pending)}>Coba ulang permintaan yang sama</button> : <span>Retry hitungan hanya tersedia saat sesi berada dalam tahap penghitungan.</span>}</div>}
            {canCount && !pending && !isEditing && <button type="button" className="secondary-button stock-opname-edit-count" disabled={!editable} onClick={() => {
              setItemEditor((current) => ({
                ...current,
                editingProduct: item.productId,
                quantityDraft: item.physicalQuantity === null ? "" : String(item.physicalQuantity),
              }));
              setFeedback(null);
            }}>{item.physicalQuantity === null ? "Masukkan hitungan" : "Ubah hitungan"}</button>}
            {canCount && !pending && isEditing && editable && <div className="stock-opname-count-editor">
              <label htmlFor={`physical-${item.productId}`}>Jumlah fisik (maks. 3 desimal)</label>
              <div><input id={`physical-${item.productId}`} type="text" inputMode="decimal" autoComplete="off" value={itemEditor.quantityDraft} onChange={(event) => setItemEditor((current) => ({ ...current, quantityDraft: event.target.value }))} placeholder="Contoh: 0 atau 12,5" />
                <button type="button" disabled={busyProduct === item.productId} onClick={() => void saveCount(item)}>{busyProduct === item.productId ? "Menyimpan…" : "Simpan hitungan"}</button></div>
              <p>Nilai nol sah. Kosong bukan nol. Gunakan titik atau koma untuk desimal. Revisi yang dikirim: {item.revision}.</p>
              <button type="button" className="stock-opname-cancel-edit" onClick={() => setItemEditor((current) => ({ ...current, editingProduct: null, quantityDraft: "" }))}>Tutup tanpa menyimpan</button>
            </div>}
            {canCount && !item.requiresRecount && !pending && <div className="stock-opname-exception-controls">
              {itemEditor.exceptionProduct !== item.productId ? <button type="button" className="secondary-button" disabled={busyProduct === item.productId} onClick={() => setItemEditor((current) => ({ ...current, exceptionProduct: item.productId, exceptionReasonDraft: "" }))}>
                {isException ? "Ubah pengecualian" : "Tandai pengecualian"}
              </button> : <div className="stock-opname-exception-editor">
                <label htmlFor={`exception-${item.productId}`}>Alasan pengecualian (wajib)</label>
                <textarea id={`exception-${item.productId}`} value={itemEditor.exceptionReasonDraft} onChange={(event) => setItemEditor((current) => ({ ...current, exceptionReasonDraft: event.target.value }))} rows={3} maxLength={1000} placeholder="Jelaskan mengapa jumlah fisik belum dapat dipastikan" />
                <p>Pengecualian bukan hitungan nol dan tidak mengubah saldo stok.</p>
                <div><button type="button" disabled={!itemEditor.exceptionReasonDraft.trim() || busyProduct === item.productId} onClick={() => void submitItemOperation("REVIEW_EXCEPTION", item, itemEditor.exceptionReasonDraft)}>{busyProduct === item.productId ? "Menyimpan…" : "Simpan pengecualian"}</button>
                  <button type="button" className="stock-opname-cancel-edit" onClick={() => setItemEditor((current) => ({ ...current, exceptionProduct: null, exceptionReasonDraft: "" }))}>Tutup tanpa menyimpan</button></div>
              </div>}
            </div>}
            {result?.kind === "error" ? <p className="stock-opname-action-error" role="alert">{result.message}</p>
              : result && <p className={`stock-opname-count-feedback ${result.kind}`} role="status">{result.message}</p>}
          </li>;
        })}
      </ol>}

      {data.pageCount > 1 && <nav className="product-pagination" aria-label="Halaman item opname"><span>Halaman {data.query.page} dari {data.pageCount}</span><div>
        {data.query.page > 1 && <Link href={hrefFor(pathname, data.query.q, data.query.filter, data.query.page - 1)}>← Sebelumnya</Link>}
        {data.query.page < data.pageCount && <Link href={hrefFor(pathname, data.query.q, data.query.filter, data.query.page + 1)}>Berikutnya →</Link>}
      </div></nav>}
    </>}
  </div>;
}
