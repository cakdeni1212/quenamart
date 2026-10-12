"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { accountErrorMessage, validateAccountInput } from "@/lib/accounts/model";

export type AccountActionResult = { ok: true; message: string } | { ok: false; message: string };

async function ownerSession() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;
  const { data: profile, error } = await supabase.from("profiles").select("role,is_active").eq("id", user.id).maybeSingle();
  if (error || !profile?.is_active || profile.role !== "OWNER") return null;
  return { supabase };
}

function domainCode(message?: string) {
  return message?.match(/ACCOUNT_[A-Z_]+/)?.[0] ?? "";
}

function rpcMessage(message?: string) {
  const code = domainCode(message ?? "");
  return code ? accountErrorMessage(code) : "Perubahan akun belum berhasil. Coba lagi.";
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? value as Record<string, unknown> : {};
}

async function deleteUnlinkedAuthUser(admin: ReturnType<typeof createAdminClient>, userId: string) {
  try {
    const { error } = await admin.auth.admin.deleteUser(userId);
    return !error;
  } catch {
    return false;
  }
}

async function invitationStatus(supabase: Awaited<ReturnType<typeof createClient>>, requestId: string) {
  try {
    const { data, error } = await supabase.rpc("account_management_invite_status", { p_request_id: requestId });
    return error ? null : asRecord(data);
  } catch {
    return null;
  }
}

async function findPendingInvitation(admin: ReturnType<typeof createAdminClient>, email: string, requestId: string) {
  // Supabase Auth Admin currently exposes paginated listing rather than lookup by email.
  // Account workspaces are small; keep recovery bounded to 10,000 Auth identities.
  const perPage = 1000;
  for (let page = 1; page <= 10; page += 1) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage });
    if (error) throw error;
    const found = data.users.find((candidate) =>
      candidate.email?.trim().toLowerCase() === email &&
      candidate.user_metadata?.quena_account_request_id === requestId,
    );
    if (found) return found;
    if (data.users.length < perPage) return null;
  }
  return null;
}

export async function createManagedAccount(input: {
  requestId: string;
  fullName: string;
  email: string;
  role: string;
}): Promise<AccountActionResult> {
  const session = await ownerSession();
  if (!session) return { ok: false, message: "Anda tidak memiliki izin mengelola akun." };
  if (!input || typeof input !== "object" || typeof input.requestId !== "string" || typeof input.fullName !== "string" || typeof input.email !== "string" || typeof input.role !== "string") {
    return { ok: false, message: "Periksa kembali data akun." };
  }
  const valid = validateAccountInput(input);
  if (!valid.ok) return { ok: false, message: valid.error };
  if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(input.requestId)) return { ok: false, message: "Permintaan akun tidak valid. Muat ulang halaman." };

  const { supabase } = session;
  let beginData: unknown;
  let beginError: { message: string } | null = null;
  try {
    const result = await supabase.rpc("account_management_invite_begin", {
      p_request_id: input.requestId,
      p_email: valid.value.email,
      p_full_name: valid.value.fullName,
      p_role: valid.value.role,
    });
    beginData = result.data;
    beginError = result.error;
  } catch {
    return { ok: false, message: "Permintaan akun belum dapat diproses. Coba lagi." };
  }
  if (beginError) return { ok: false, message: rpcMessage(beginError.message) };
  const begin = asRecord(beginData);
  if (begin.state === "COMPLETED") {
    revalidatePath("/pengaturan/akun");
    return { ok: true, message: "Undangan sudah diproses. Akun tampil pada daftar pengguna." };
  }
  if (begin.state === "PROCESSING") return { ok: false, message: "Undangan sedang diproses. Tunggu sebentar lalu muat ulang daftar." };
  const claimToken = typeof begin.claim_token === "string" ? begin.claim_token : "";
  if (!claimToken) return { ok: false, message: "Permintaan akun belum dapat dilanjutkan. Muat ulang lalu coba kembali." };

  let admin: ReturnType<typeof createAdminClient>;
  try {
    admin = createAdminClient();
  } catch {
    await supabase.rpc("account_management_invite_fail", { p_request_id: input.requestId, p_claim_token: claimToken });
    return { ok: false, message: "Undangan belum tersedia. Periksa konfigurasi layanan Auth server." };
  }

  let authUser: { id: string; email?: string | undefined } | null = null;
  const attachedId = typeof begin.user_id === "string" ? begin.user_id : null;
  if (attachedId) {
    try {
      const { data, error } = await admin.auth.admin.getUserById(attachedId);
      if (error || !data.user || data.user.email?.toLowerCase() !== valid.value.email) {
        return { ok: false, message: "Identitas undangan belum dapat diverifikasi. Coba lagi atau hubungi administrator sistem." };
      }
      authUser = data.user;
    } catch {
      return { ok: false, message: "Identitas undangan belum dapat diverifikasi. Coba lagi atau hubungi administrator sistem." };
    }
  } else {
    try {
      authUser = await findPendingInvitation(admin, valid.value.email, input.requestId);
    } catch {
      return { ok: false, message: "Status undangan belum dapat diverifikasi. Coba lagi." };
    }
    if (!authUser) {
      const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;
      let redirectTo: string | undefined;
      if (siteUrl) {
        try { redirectTo = new URL("/auth/confirm", siteUrl).toString(); } catch {
          await supabase.rpc("account_management_invite_fail", { p_request_id: input.requestId, p_claim_token: claimToken });
          return { ok: false, message: "Alamat aplikasi untuk undangan belum dikonfigurasi dengan benar." };
        }
      }
      let invitation: Awaited<ReturnType<typeof admin.auth.admin.inviteUserByEmail>>;
      try {
        invitation = await admin.auth.admin.inviteUserByEmail(valid.value.email, {
          data: { full_name: valid.value.fullName, quena_account_request_id: input.requestId },
          ...(redirectTo ? { redirectTo } : {}),
        });
      } catch {
        await supabase.rpc("account_management_invite_fail", { p_request_id: input.requestId, p_claim_token: claimToken });
        return { ok: false, message: "Undangan tidak terkirim. Periksa konfigurasi email Auth lalu coba kembali." };
      }
      const { data, error } = invitation;
      if (error || !data.user) {
        const duplicate = /already|registered|exists/i.test(error?.message ?? "");
        await supabase.rpc("account_management_invite_fail", { p_request_id: input.requestId, p_claim_token: claimToken });
        return { ok: false, message: duplicate ? "Email sudah digunakan." : "Undangan tidak terkirim. Periksa konfigurasi email Auth lalu coba kembali." };
      }
      authUser = data.user;
    }
  }

  if (!authUser) return { ok: false, message: "Identitas undangan belum ditemukan. Coba lagi." };
  let attached = attachedId === authUser.id;
  if (!attached) {
    const { error } = await supabase.rpc("account_management_invite_attach", {
      p_request_id: input.requestId,
      p_claim_token: claimToken,
      p_auth_user_id: authUser.id,
    });
    if (error) {
      const state = await invitationStatus(supabase, input.requestId);
      attached = state?.state === "PENDING" && state.user_id === authUser.id;
      if (!attached) {
        if (state) {
          const deleted = await deleteUnlinkedAuthUser(admin, authUser.id);
          if (deleted) await supabase.rpc("account_management_invite_fail", { p_request_id: input.requestId, p_claim_token: claimToken });
        }
        return { ok: false, message: "Profil akun belum dapat disimpan. Akses aplikasi tetap tertutup sampai profil aktif dibuat; coba ulang permintaan yang sama." };
      }
    } else attached = true;
  }

  const { error: completeError } = await supabase.rpc("account_management_invite_complete", {
    p_request_id: input.requestId,
    p_claim_token: claimToken,
    p_auth_user_id: authUser.id,
  });
  if (completeError) {
    const state = await invitationStatus(supabase, input.requestId);
    if (state?.state === "COMPLETED" && state.user_id === authUser.id) {
      revalidatePath("/pengaturan/akun");
      return { ok: true, message: "Undangan berhasil dikirim. Pengguna dapat menyiapkan kata sandi dari email." };
    }
    if (state?.state === "PENDING" && state.user_id === authUser.id) {
      const deleted = await deleteUnlinkedAuthUser(admin, authUser.id);
      if (deleted) await supabase.rpc("account_management_invite_fail", { p_request_id: input.requestId, p_claim_token: claimToken });
    }
    return { ok: false, message: "Profil akun belum dapat disimpan. Coba kembali; status permintaan diperiksa agar tidak membuat akun ganda." };
  }

  revalidatePath("/pengaturan/akun");
  return { ok: true, message: "Undangan berhasil dikirim. Pengguna dapat menyiapkan kata sandi dari email." };
}

export async function updateManagedAccount(input: {
  targetUserId: string;
  fullName: string;
  role: string;
  isActive: boolean;
}): Promise<AccountActionResult> {
  const session = await ownerSession();
  if (!session) return { ok: false, message: "Anda tidak memiliki izin mengelola akun." };
  if (!input || typeof input !== "object" || typeof input.targetUserId !== "string" || typeof input.fullName !== "string" || typeof input.role !== "string" || typeof input.isActive !== "boolean") return { ok: false, message: "Periksa kembali data akun." };
  if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(input.targetUserId)) return { ok: false, message: "Akun tidak valid." };
  const fullName = input.fullName.trim();
  if (!fullName || fullName.length > 120 || !["ADMIN", "KASIR", "GUDANG"].includes(input.role)) {
    return { ok: false, message: "Periksa kembali nama dan hak akses akun." };
  }
  let error: { message: string } | null;
  try {
    const result = await session.supabase.rpc("account_management_update", {
      p_target_user_id: input.targetUserId,
      p_full_name: fullName,
      p_role: input.role,
      p_is_active: input.isActive,
    });
    error = result.error;
  } catch {
    return { ok: false, message: "Perubahan akun belum berhasil. Coba lagi." };
  }
  if (error) return { ok: false, message: rpcMessage(error.message) };
  revalidatePath("/pengaturan/akun");
  return { ok: true, message: input.isActive ? "Data akun berhasil diperbarui." : "Akun dinonaktifkan. Riwayat aktivitas tetap tersimpan." };
}
