import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";
import { readPosCartWorkspace } from "@/lib/pos/cart-read";
import { createPosCart } from "@/app/actions/pos-cart";
import { PosWorkspace } from "@/components/pos/pos-workspace";
import { readEffectivePosSettings } from "@/lib/settings/pos.server";

export default async function KasirPage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "kasir")) redirect("/dashboard");

  let workspace = await readPosCartWorkspace();
  const posSettings = await readEffectivePosSettings();
  let initialError = workspace.error;
  if (!workspace.carts.some((cart) => cart.status === "ACTIVE") && !workspace.error) {
    const created = await createPosCart(crypto.randomUUID());
    if (created.ok) workspace = await readPosCartWorkspace();
    else initialError = created.message;
  }

  return <main className="page-content pos-page">
    <header className="pos-page-heading"><div><div className="eyebrow">KASIR</div><h1>Kasir</h1></div><p>Scan barcode atau cari produk untuk mulai transaksi.</p></header>
    <PosWorkspace initialCarts={workspace.carts} initialError={initialError} settings={posSettings} />
  </main>;
}
