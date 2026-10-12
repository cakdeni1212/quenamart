import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/auth/session";
import { readAccountDirectory } from "@/lib/accounts/read";
import { AccountManagementWorkspace, CreateAccountButton } from "@/components/accounts/account-management-workspace";
import styles from "@/components/accounts/accounts.module.css";

type SearchParams = Record<string, string | string[] | undefined>;
const first = (value: string | string[] | undefined) => Array.isArray(value) ? value[0] : value;

export default async function AccountManagementPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const profile = await requireProfile();
  if (profile.role !== "OWNER") redirect("/dashboard");
  const params = await searchParams;
  const search = first(params.q) ?? "";
  const role = first(params.role) ?? "";
  const status = first(params.status) ?? "";
  const page = Math.max(1, Number.parseInt(first(params.halaman) ?? "1", 10) || 1);
  const result = await readAccountDirectory({ search, role, status, page });
  const pageCount = Math.max(1, Math.ceil(result.total / 25));
  return <main className={`page-content ${styles.page}`}>
    <header className={styles.heading}>
      <div><div className="eyebrow">AKUN &amp; AKSES</div><h1>Akun Pengguna</h1><p>Kelola akun dan hak akses tim Quena Mart.</p></div>
      <CreateAccountButton />
    </header>
    <AccountManagementWorkspace
      rows={result.rows}
      error={result.error}
      total={result.total}
      page={page}
      pageCount={pageCount}
      search={search}
      roleFilter={role}
      statusFilter={status}
      currentUserId={profile.id}
    />
  </main>;
}
