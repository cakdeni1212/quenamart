"use server";

import { createHmac, randomUUID } from "node:crypto";
import { isIP } from "node:net";
import { headers } from "next/headers";
import { createAdminClient } from "@/lib/supabase/admin";

export type PublicMemberRegistrationResult =
  | { ok: true; status: "CREATED"; memberNumber: string }
  | { ok: false; status: "ALREADY_REGISTERED" | "RATE_LIMITED" | "INVALID" | "UNAVAILABLE"; message: string };

const normalizePhone = (phone: string) => {
  const digits = phone.replace(/\D/g, "").replace(/^00/, "");
  return digits.startsWith("0") ? `62${digits.slice(1)}` : digits;
};

function digest(value: string, key: string) {
  return createHmac("sha256", key).update(value).digest("hex");
}

export async function registerPublicMember(input: {
  name: string;
  phone: string;
  email: string;
  serviceConsent: boolean;
  promotionalConsent: boolean;
}): Promise<PublicMemberRegistrationResult> {
  const name = typeof input?.name === "string" ? input.name.trim() : "";
  const phone = typeof input?.phone === "string" ? input.phone.trim() : "";
  const email = typeof input?.email === "string" ? input.email.trim() : "";
  const normalizedPhone = normalizePhone(phone);
  if (!input?.serviceConsent || name.length < 1 || name.length > 160 || phone.length > 40
    || !/^[0-9]{8,15}$/.test(normalizedPhone)
    || (email && (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)))) {
    return { ok: false, status: "INVALID", message: "Periksa nama, nomor WhatsApp, email, dan persetujuan Anda." };
  }

  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!secret) return { ok: false, status: "UNAVAILABLE", message: "Pendaftaran belum tersedia. Silakan coba lagi nanti." };
  const requestHeaders = await headers();
  const forwarded = requestHeaders.get("x-forwarded-for")?.split(",").at(-1)?.trim();
  const ip = requestHeaders.get("x-real-ip")?.trim() || forwarded;
  if (!ip || !isIP(ip)) return { ok: false, status: "UNAVAILABLE", message: "Pendaftaran belum tersedia dari jaringan ini." };

  try {
    const { data, error } = await createAdminClient().rpc("member_public_register", {
      p_full_name: name,
      p_phone: phone,
      p_email: email || null,
      p_request_id: randomUUID(),
      p_ip_digest: digest(ip, secret),
      p_phone_digest: digest(normalizedPhone, secret),
      p_membership_consent: true,
      p_promotional_consent: Boolean(input.promotionalConsent),
    });
    if (error) {
      console.error("[member_public_register] Registration RPC failed", { code: error.code, message: error.message });
      return { ok: false, status: "UNAVAILABLE", message: "Pendaftaran belum dapat diproses. Silakan coba lagi nanti." };
    }
    if (typeof data !== "object" || data === null || Array.isArray(data)) {
      console.error("[member_public_register] Invalid response contract");
      return { ok: false, status: "UNAVAILABLE", message: "Pendaftaran belum dapat diproses. Silakan coba lagi nanti." };
    }
    const result = data as Record<string, unknown>;
    if (result.status === "CREATED" && typeof result.member_number === "string") {
      return { ok: true, status: "CREATED", memberNumber: result.member_number };
    }
    if (result.status === "ALREADY_REGISTERED") {
      return { ok: false, status: "ALREADY_REGISTERED", message: "Nomor WhatsApp ini sudah terdaftar sebagai Member Quena Mart. Silakan cek poin setelah verifikasi tersedia." };
    }
    if (result.status === "RATE_LIMITED") {
      return { ok: false, status: "RATE_LIMITED", message: "Terlalu banyak percobaan. Silakan coba lagi beberapa saat." };
    }
    console.error("[member_public_register] Unexpected status", { status: result.status });
    return { ok: false, status: "UNAVAILABLE", message: "Pendaftaran belum dapat diproses. Silakan coba lagi nanti." };
  } catch (error) {
    console.error("[member_public_register] Unexpected registration failure", error instanceof Error ? error.message : "unknown");
    return { ok: false, status: "UNAVAILABLE", message: "Pendaftaran belum dapat diproses. Silakan coba lagi nanti." };
  }
}
