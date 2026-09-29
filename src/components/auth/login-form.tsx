"use client";

import { useActionState } from "react";
import { login, type LoginState } from "@/app/actions/auth";

const initialState: LoginState = {};

export function LoginForm() {
  const [state, action, pending] = useActionState(login, initialState);

  return (
    <form action={action} className="mt-8 space-y-5">
      <label className="field-label">
        Email
        <input className="field-input" type="email" name="email" autoComplete="email" required placeholder="nama@tokomu.com" />
      </label>
      <label className="field-label">
        Kata sandi
        <input className="field-input" type="password" name="password" autoComplete="current-password" required placeholder="Masukkan kata sandi" />
      </label>
      {state.error && <p role="alert" className="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">{state.error}</p>}
      <button className="primary-button w-full" type="submit" disabled={pending}>
        {pending ? "Memeriksa akses…" : "Masuk ke Quena Mart"}
      </button>
    </form>
  );
}
