"use client";

import { useActionState } from "react";
import { setInitialPassword, type PasswordSetupResult } from "@/app/actions/account-password";

export function SetupPasswordForm() {
  const [state, action, pending] = useActionState<PasswordSetupResult, FormData>(setInitialPassword, {});
  return <form action={action} className="login-form">
    <label htmlFor="password">Kata sandi baru</label>
    <input id="password" name="password" type="password" minLength={8} autoComplete="new-password" required />
    <label htmlFor="confirmation">Ulangi kata sandi</label>
    <input id="confirmation" name="confirmation" type="password" minLength={8} autoComplete="new-password" required />
    {state.error && <p className="login-error" role="alert">{state.error}</p>}
    <button type="submit" disabled={pending}>{pending ? "Menyimpan…" : "Simpan Kata Sandi"}</button>
  </form>;
}
