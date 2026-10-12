import { InviteConfirmation } from "@/components/auth/invite-confirmation";

export default function InviteConfirmationPage() {
  return <main className="login-page"><section className="login-panel"><div className="login-copy"><div className="eyebrow">AKUN QUENA MART</div><h1>Memeriksa undangan.</h1><InviteConfirmation /></div><div className="login-foot">Gunakan akun Quena Mart yang sama pada Web/PWA dan aplikasi Android mendatang.</div></section><aside className="login-art"><div className="art-glow" /><div className="art-top"><span>QUENA MART</span><span>RETAIL · PEOPLE · GROWTH</span></div><div className="art-message"><div className="art-symbol">Q</div><p>Akses tim,<br /><em>tetap aman.</em></p><span>Satu identitas untuk ruang kerja Quena Mart.</span></div><div className="art-bottom"><span>01 — 04</span><span>BUILT FOR EVERYDAY RETAIL</span></div></aside></main>;
}
