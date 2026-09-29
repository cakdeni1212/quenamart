import { redirect } from "next/navigation";
import { IposImportForm } from "@/components/imports/ipos-import-form";
import { canAccessSection } from "@/lib/auth/roles";
import { requireProfile } from "@/lib/auth/session";

export default async function ImportIposPage() {
  const profile = await requireProfile();
  if (!canAccessSection(profile.role, "import-ipos")) redirect("/dashboard");

  return (
    <main className="page-content">
      <div className="eyebrow">DATA & PRODUK</div>
      <h1>Import Data iPos</h1>
      <p className="page-lead">Unggah file asli iPos untuk membuat permintaan import.</p>
      <IposImportForm />
    </main>
  );
}
