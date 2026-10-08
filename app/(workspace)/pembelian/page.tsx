import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { canAccessSection } from "@/lib/auth/roles";

export default async function PurchasingHomePage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "pembelian")) redirect("/dashboard");
  redirect("/pembelian/barang-masuk");
}
