"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export function InviteConfirmation() {
  const router = useRouter();
  const started = useRef(false);
  const [message, setMessage] = useState("Tautan sedang diverifikasi dengan Supabase Auth.");
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const url = new URL(window.location.href);
    const tokenHash = url.searchParams.get("token_hash");
    const type = url.searchParams.get("type");
    const hash = new URLSearchParams(url.hash.replace(/^#/, ""));
    const accessToken = hash.get("access_token");
    const refreshToken = hash.get("refresh_token");
    window.history.replaceState(null, "", url.pathname);

    void (async () => {
      const supabase = createClient();
      const result = tokenHash && type === "invite"
        ? await supabase.auth.verifyOtp({ token_hash: tokenHash, type: "invite" })
        : accessToken && refreshToken
          ? await supabase.auth.setSession({ access_token: accessToken, refresh_token: refreshToken })
          : { error: new Error("Invalid invite link") };
      if (result.error) {
        setMessage("Tautan undangan tidak valid atau sudah kedaluwarsa. Minta Owner mengirim undangan baru.");
        setFailed(true);
        return;
      }
      setMessage("Undangan terverifikasi. Menyiapkan halaman akun…");
      router.replace("/auth/setup-password");
      router.refresh();
    })();
  }, [router]);

  return <div><p>{message}</p>{failed && <Link className="quiet-button" href="/login">Kembali ke halaman masuk</Link>}</div>;
}
