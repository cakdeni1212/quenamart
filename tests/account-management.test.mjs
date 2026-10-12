import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const migration = read("../supabase/migrations/20260929420000_account_access_management_v1.sql");
const action = read("../src/app/actions/account-management.ts");
const roles = read("../src/lib/auth/roles.ts");
const session = read("../src/lib/auth/session.ts");
const directory = read("../src/lib/accounts/read.ts");
const confirmPage = read("../app/auth/confirm/page.tsx");
const confirmClient = read("../src/components/auth/invite-confirmation.tsx");
const passwordAction = read("../src/app/actions/account-password.ts");
const workspace = read("../src/components/accounts/account-management-workspace.tsx");
const architecture = read("../docs/ARCHITECTURE.md");
const primaryActionStyles = read("../src/components/ui/workspace-primary-action.module.css");
const model = await import("../src/lib/accounts/model.ts");

test("account workspace and every data contract are OWNER-only", () => {
  assert.match(roles, /akun: \["OWNER"\]/);
  assert.match(migration, /account_management_list[\s\S]*current_active_user_role\(\) IS DISTINCT FROM 'OWNER'/);
  for (const fn of ["account_management_invite_begin", "account_management_invite_attach", "account_management_invite_complete", "account_management_invite_status", "account_management_invite_fail", "account_management_update"]) {
    const start = migration.indexOf(`FUNCTION public.${fn}`);
    assert.notEqual(start, -1, `${fn} exists`);
    assert.match(migration.slice(start, start + 1300), /current_active_user_role\(\) IS DISTINCT FROM 'OWNER'/, `${fn} checks Owner server-side`);
  }
  assert.match(directory, /account_management_list/);
  assert.match(workspace, /Akun Owner dilindungi/);
});

test("identity stays on Auth UUID and inactive profiles are denied by existing guards", () => {
  assert.match(session, /auth\.getUser\(\)/);
  assert.match(session, /\.eq\("id", user\.id\)/);
  assert.match(session, /!data\.is_active/);
  assert.match(migration, /VALUES\(p_auth_user_id,v_request\.full_name,v_request\.requested_role,true\)/);
  assert.match(migration, /INSERT INTO public\.profiles\(id,full_name,role,is_active\)/);
  assert.match(architecture, /same Supabase Auth identity/);
  assert.match(architecture, /inactive profiles are denied/i);
});

test("Auth Admin is server-only and invitations do not collect or persist passwords", () => {
  assert.match(action, /import \{ createAdminClient \} from "@\/lib\/supabase\/admin"/);
  assert.match(action, /inviteUserByEmail/);
  assert.match(action, /quena_account_request_id/);
  assert.match(action, /account_management_invite_attach/);
  assert.match(action, /account_management_invite_complete/);
  assert.match(action, /deleteUnlinkedAuthUser\(admin, authUser\.id\)/);
  assert.match(action, /admin\.auth\.admin\.deleteUser\(userId\)/);
  assert.doesNotMatch(action, /password\s*:/i);
  const requestTable = migration.slice(migration.indexOf("CREATE TABLE public.account_provisioning_requests"), migration.indexOf("CREATE UNIQUE INDEX"));
  assert.doesNotMatch(requestTable, /password|access_token|refresh_token|service_role_key/i);
  assert.match(confirmClient, /verifyOtp\(\{ token_hash: tokenHash, type: "invite" \}\)/);
  assert.match(confirmClient, /setSession\(\{ access_token: accessToken, refresh_token: refreshToken \}\)/);
  assert.match(confirmPage, /InviteConfirmation/);
  assert.match(passwordAction, /updateUser\(\{ password \}\)/);
});

test("invitation request is replay-safe, rejects conflicting payloads and binds requested roles", () => {
  assert.match(migration, /request_id uuid PRIMARY KEY/);
  assert.match(migration, /ACCOUNT_REQUEST_CONFLICT/);
  assert.match(migration, /ACCOUNT_EMAIL_EXISTS/);
  assert.match(migration, /ACCOUNT_INVITATION_PENDING/);
  assert.match(migration, /raw_user_meta_data->>'quena_account_request_id'/);
  assert.match(migration, /'COMPLETED','user_id',v_request\.auth_user_id/);
  assert.match(migration, /claim_expires_at/);
  assert.match(migration, /requested_role public\.user_role NOT NULL CHECK/);
  assert.match(action, /begin\.state === "COMPLETED"/);
  assert.match(action, /begin\.state === "PROCESSING"/);
  assert.match(action, /invitationStatus\(supabase, input\.requestId\)/);
});

test("no hard-delete path exists; updates preserve actor rows and protect self/Owner", () => {
  assert.doesNotMatch(migration, /DELETE\s+FROM\s+public\.profiles/i);
  assert.match(migration, /ACCOUNT_SELF_CHANGE_FORBIDDEN/);
  assert.match(migration, /ACCOUNT_LAST_ACTIVE_OWNER/);
  assert.match(migration, /ACCOUNT_OWNER_REQUIRES_ELEVATED_FLOW/);
  assert.match(migration, /UPDATE public\.profiles SET full_name/);
  assert.match(migration, /ON DELETE RESTRICT/);
  assert.match(workspace, /Pengguna tidak dapat mengakses Quena Mart setelah akun dinonaktifkan/);
});

test("account list is bounded, filterable and returns only safe identity fields", () => {
  assert.match(migration, /p_limit<1 OR p_limit>50/);
  assert.match(migration, /p_offset>50000/);
  assert.match(migration, /ORDER BY lower\(coalesce\(full_name,''\)\),id LIMIT p_limit OFFSET p_offset/);
  assert.match(migration, /'last_sign_in_at',r\.last_sign_in_at/);
  assert.doesNotMatch(migration, /password_hash|encrypted_password|refresh_token|access_token/);
  assert.match(directory, /p_limit: 25/);
  assert.match(directory, /slice\(0, 100\)/);
  assert.match(read("../src/lib/accounts/model.ts"), /Belum tersedia/);
  assert.doesNotMatch(workspace, /profiles\.updated_at/);
});

test("same Supabase identity supports Web/PWA and future Android Gudang", () => {
  assert.match(roles, /GUDANG/);
  assert.match(architecture, /future Android clients/);
  assert.match(architecture, /does not get a parallel employee or role store/);
  assert.match(architecture, /GUDANG/);
});

test("account input normalizes email and validates supported human roles", () => {
  assert.deepEqual(model.validateAccountInput({ fullName: "  Budi Santoso  ", email: " BUDI@EXAMPLE.COM ", role: "GUDANG" }), {
    ok: true,
    value: { fullName: "Budi Santoso", email: "budi@example.com", role: "GUDANG" },
  });
  assert.equal(model.validateAccountInput({ fullName: "", email: "budi@example.com", role: "KASIR" }).error, "Masukkan nama lengkap (maksimal 120 karakter).");
  assert.equal(model.validateAccountInput({ fullName: "Budi", email: "not-email", role: "KASIR" }).error, "Masukkan email yang valid.");
  assert.equal(model.validateAccountInput({ fullName: "Budi", email: "budi@example.com", role: "OWNER" }).error, "Pilih hak akses yang tersedia.");
  assert.match(model.accountDateTime(null), /Belum tersedia/);
  assert.match(model.accountDateTime("not a date"), /Belum tersedia/);
  assert.equal(model.accountErrorMessage("ACCOUNT_UNAUTHORIZED"), "Anda tidak memiliki izin mengelola akun.");
  assert.doesNotMatch(model.accountErrorMessage("SQLSTATE 42501 raw detail"), /SQLSTATE|DETAIL|42501/);
});

test("workspace create actions share the canonical primary action style", () => {
  assert.match(workspace, /primaryAction\.primary} type="button" onClick=\{show\}>\+ Tambah Akun/);
  assert.match(primaryActionStyles, /\.primary[\s\S]*?min-height: 39px[\s\S]*?background: #316447/);
  assert.match(primaryActionStyles, /:hover/);
  assert.match(primaryActionStyles, /:focus-visible/);
  assert.match(primaryActionStyles, /:disabled/);
  assert.match(primaryActionStyles, /\.secondary[\s\S]*?min-height: 42px[\s\S]*?background: #f2f7ef[\s\S]*?color: #426743/);
  assert.match(primaryActionStyles, /\.danger/);
  assert.match(primaryActionStyles, /\.ghost/);
  assert.match(workspace, /primaryAction\.secondary} type="submit">Terapkan/);
  assert.match(read("../app/(workspace)/produk/page.tsx"), /primaryAction\.primary/);
  assert.match(read("../app/(workspace)/transaksi/page.tsx"), /primaryAction\.primary/);
});
