import { readWhatsAppSaleDeliveryStatus } from "@/app/actions/pos-cart";
import styles from "@/components/sales/sales-history.module.css";

const labels: Record<string, string> = {
  SENT: "Terkirim", PENDING: "Menunggu", RETRY: "Menunggu percobaan ulang", FAILED: "Gagal",
  PROCESSING: "Sedang diproses", CANCELLED: "Dibatalkan", BLOCKED: "Ditahan",
  NO_MEMBER: "Tidak ada member", NOT_ELIGIBLE: "Tidak memenuhi syarat pengiriman",
  AUTOMATION_DISABLED: "Pengiriman otomatis nonaktif", NOT_QUEUED: "Belum masuk antrean",
};
export async function WhatsAppDeliveryStatus({ saleId }: { saleId: string }) {
  const result = await readWhatsAppSaleDeliveryStatus(saleId);
  if (!result.ok || typeof result.value.status !== "string") return null;
  return <section className={styles.detailCard}><h2>WhatsApp</h2><p>{labels[result.value.status] ?? "Status belum tersedia"}</p></section>;
}
