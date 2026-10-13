import { redirect } from "next/navigation";
import { IposSalesImportWorkspace } from "@/components/sales/ipos-sales-import-workspace";
import { landingPathForRole } from "@/lib/auth/roles";
import { requireProfile } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { projectIposSalesBatch } from "@/lib/ipos-sales/ui-payload";

type Params = { batch?: string | string[] };
type Dict = Record<string, unknown>;
const record = (value: unknown): Dict => value && typeof value === "object" && !Array.isArray(value) ? value as Dict : {};
const string = (value: unknown) => typeof value === "string" ? value : "";

export default async function IposSalesImportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const profile = await requireProfile();
  if (!profile.is_active || (profile.role !== "OWNER" && profile.role !== "ADMIN")) redirect(landingPathForRole(profile.role));
  const params = await searchParams;
  const batchParam = Array.isArray(params.batch) ? params.batch[0] : params.batch;
  const validBatchParam = Boolean(batchParam && /^[0-9a-f-]{36}$/i.test(batchParam));
  const supabase = await createClient();
  const [batchResult, recentResult] = await Promise.all([
    validBatchParam
      ? supabase.rpc("ipos_sales_import_batch_read", { p_batch_id: batchParam })
      : Promise.resolve({ data: null, error: null }),
    supabase.rpc("ipos_sales_import_batches_read", { p_limit: 8 }),
  ]);
  const recent = Array.isArray(recentResult.data) ? recentResult.data.map((value) => {
    const row = record(value);
    return { id: string(row.id), reportFrom: string(row.reportFrom), reportTo: string(row.reportTo), filename: string(row.filename), transactions: Number(row.transactions ?? 0), lines: Number(row.lines ?? 0), amount: string(row.amount), status: string(row.status) };
  }).filter((row) => row.id) : [];
  const initialError = batchParam
    ? !validBatchParam || batchResult.error || !batchResult.data
      ? "Laporan tidak ditemukan atau Anda tidak memiliki akses."
      : null
    : null;

  return <main className="page-content">
    <IposSalesImportWorkspace
      key={batchParam ?? "upload"}
      initialBatch={batchResult.error ? null : projectIposSalesBatch(batchResult.data)}
      initialError={initialError}
      recent={recent}
    />
  </main>;
}
