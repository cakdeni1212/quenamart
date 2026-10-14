import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("public signup uses a narrow server-only registration RPC with separate immutable consent", async () => {
  const [migration, action, form] = await Promise.all([
    read("supabase/migrations/20260929478000_member_public_access_foundation_v1.sql"),
    read("src/app/actions/public-members.ts"),
    read("src/components/members/public-member-registration-form.tsx"),
  ]);
  assert.match(migration, /CREATE TABLE public\.member_consent_evidence/);
  assert.match(migration, /MEMBERSHIP_SERVICE/);
  assert.match(migration, /PROMOTIONAL_WHATSAPP/);
  assert.match(migration, /guard_member_consent_immutable/);
  assert.match(migration, /auth\.role\(\) IS DISTINCT FROM 'service_role'/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.member_public_register[\s\S]* TO service_role/);
  assert.match(migration, /FROM PUBLIC,anon,authenticated/);
  assert.match(action, /createAdminClient\(\)\.rpc\("member_public_register"/);
  assert.match(action, /createHmac\("sha256", key\)/);
  assert.match(action, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(form, /serviceConsent/);
  assert.match(form, /promotionalConsent/);
  assert.doesNotMatch(form, /password|member_token|point_balance/);
});

test("public membership pages are outside staff workspace and phone-only balance access fails closed", async () => {
  const [landing, registration, points, workspace] = await Promise.all([
    read("app/member-quena/page.tsx"),
    read("app/member-quena/daftar/page.tsx"),
    read("app/member-quena/cek/page.tsx"),
    read("app/(workspace)/layout.tsx"),
  ]);
  assert.match(landing, /Daftar Member/);
  assert.match(landing, /Cek Poin/);
  assert.match(registration, /PublicMemberRegistrationForm/);
  assert.match(points, /Verifikasi WhatsApp belum tersedia/);
  assert.match(points, /Nomor telepon saja tidak dapat digunakan/);
  assert.match(workspace, /requireProfile/);
  assert.doesNotMatch(landing + registration + points, /WorkspaceShell|Sidebar|requireProfile/);
});

test("POS member code lookup is exact on Enter, cashier registration attaches atomically, and reads mask phone", async () => {
  const [migration, action, workspace] = await Promise.all([
    read("supabase/migrations/20260929478000_member_public_access_foundation_v1.sql"),
    read("src/app/actions/pos-cart.ts"),
    read("src/components/pos/pos-workspace.tsx"),
  ]);
  assert.match(migration, /member_mask_phone\(phone\) phone_masked/);
  assert.match(migration, /member_token::text=q/);
  assert.match(migration, /\) exact_match/);
  assert.match(migration, /pos_cart_member_set\(p_cart/);
  assert.match(migration, /MEMBERSHIP_SERVICE.*POS_ENROLLMENT/);
  assert.match(workspace, /event\.key === "Enter"[\s\S]*lookupExactMember/);
  assert.match(workspace, /placeholder="Cari nama, nomor WA, ID Member, atau scan kartu"/);
  assert.match(workspace, /registerPosMember\(/);
  assert.match(workspace, /phone_masked/);
  assert.match(action, /value: \{ member_number: result\.value\.member_number \}/);
  assert.match(migration, /member_pos_cart_read/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.member_pos_search\(text,integer\) TO authenticated/);
});

test("public and personal QR targets use local QR generation and configured base URL, not a hosted QR service", async () => {
  const [settingsPage, personalPage, generic, detail, packageJson] = await Promise.all([
    read("app/(workspace)/pengaturan/member-poin/page.tsx"),
    read("app/(workspace)/member/[id]/page.tsx"),
    read("src/components/settings/member-public-qr.tsx"),
    read("src/components/members/member-detail-workspace.tsx"),
    read("package.json"),
  ]);
  assert.match(settingsPage, /NEXT_PUBLIC_APP_URL/);
  assert.match(settingsPage, /QRCode\.toDataURL/);
  assert.match(settingsPage, /profile\.role === "OWNER"/);
  assert.match(personalPage, /QRCode\.toDataURL\(token/);
  assert.match(personalPage, /delete safeMember\.member_token/);
  assert.match(generic, /QR umum menuju halaman Member Quena Mart/);
  assert.match(detail, /Kode ini untuk pencarian cepat oleh kasir/);
  assert.match(packageJson, /"qrcode"/);
  assert.doesNotMatch(settingsPage + personalPage, /localhost:3000|localhost:3001|api\.qrserver|quickchart/);
});
