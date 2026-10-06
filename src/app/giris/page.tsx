"use client";
import { Suspense, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { ChevronLeft, ShoppingBag, UserRound, BriefcaseBusiness } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/field";
import { Alert, Card } from "@/components/ui/card";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { SITE_URL } from "@/lib/env";
import { loginEmail, normalizePhone } from "@/lib/username";

type Mode = "musteri" | "calisan";

function LoginForm({ mode }: { mode: Mode }) {
  const params = useSearchParams();
  const [login, setLogin] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const isCustomer = mode === "musteri";

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    if (isCustomer && !normalizePhone(login)) return setError("Cep telefonu numaranızı 05xx xxx xx xx biçiminde yazın.");
    setLoading(true);
    const { error } = await supabaseBrowser().auth.signInWithPassword({ email: loginEmail(login), password });
    setLoading(false);
    if (error) {
      setError(/invalid login/i.test(error.message) ? (isCustomer ? "Telefon veya şifre hatalı." : "Kullanıcı adı veya şifre hatalı.") : errorMessage(error));
      return;
    }
    const next = params.get("next");
    // Yalnızca site içi adres (//evil.com, /\evil.com gibi dış yönlendirmeler reddedilir)
    const safe = next && /^\/(?![\/\\])/.test(next) && !next.includes("\\") ? next : "/";
    window.location.assign(safe);
  }

  async function reset() {
    if (isCustomer || !login.includes("@")) {
      setError(isCustomer ? "Şifrenizi unuttuysanız bizi arayın; size yeni geçici şifre verelim." : "Kullanıcı adıyla giriş yapanların şifresini yönetici sıfırlar. Lütfen yöneticinize başvurun.");
      return;
    }
    setError(null);
    const { error } = await supabaseBrowser().auth.resetPasswordForEmail(login.trim(), {
      redirectTo: `${window.location.origin || SITE_URL}/auth/callback?next=/sifre`,
    });
    if (error) setError(errorMessage(error));
    else setInfo("Şifre sıfırlama bağlantısı e-posta adresinize gönderildi.");
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <Field label={isCustomer ? "Cep telefonu" : "Kullanıcı adı veya e-posta"}>
        <Input
          type={isCustomer ? "tel" : "text"}
          inputMode={isCustomer ? "tel" : undefined}
          autoComplete={isCustomer ? "tel" : "username"}
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          placeholder={isCustomer ? "05xx xxx xx xx" : undefined}
          required
          value={login}
          onChange={(e) => setLogin(e.target.value)}
        />
      </Field>
      <Field label="Şifre">
        <Input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
      </Field>
      {error ? <Alert>{error}</Alert> : null}
      {info ? <Alert tone="ok">{info}</Alert> : null}
      <Button type="submit" size="lg" className="w-full" loading={loading}>Giriş yap</Button>
      <button type="button" onClick={reset} className="w-full text-center text-sm text-brand">Şifremi unuttum</button>
    </form>
  );
}

function Choice({ href, icon: Icon, title, text, primary }: { href: string; icon: typeof ShoppingBag; title: string; text: string; primary?: boolean }) {
  return (
    <Link
      href={href}
      className={`flex items-center gap-4 rounded-2xl border p-4 active:scale-[0.99] ${primary ? "border-brand bg-brand text-white" : "border-border bg-surface hover:bg-surface-2"}`}
    >
      <Icon className="h-8 w-8 shrink-0" />
      <span>
        <span className="block text-lg font-semibold">{title}</span>
        <span className={`block text-sm ${primary ? "text-white/85" : "text-muted"}`}>{text}</span>
      </span>
    </Link>
  );
}

function Entry() {
  const params = useSearchParams();
  const router = useRouter();
  const tip = params.get("tip");
  const mode: Mode | null = tip === "musteri" || tip === "calisan" ? tip : params.get("next") ? "calisan" : null;

  if (!mode) {
    return (
      <div className="space-y-3">
        <Choice href="/siparis-ver" icon={ShoppingBag} title="Sipariş ver" text="İlk kez mi sipariş veriyorsunuz? Adresinizi girin, siparişiniz kapınıza gelsin." primary />
        <Choice href="/giris?tip=musteri" icon={UserRound} title="Kayıtlı müşteri girişi" text="Telefon numaranız ve şifrenizle girin." />
        <Choice href="/giris?tip=calisan" icon={BriefcaseBusiness} title="Çalışan girişi" text="Personel ve bayiler için." />
      </div>
    );
  }
  return (
    <div className="space-y-4">
      <button type="button" onClick={() => router.push("/giris")} className="flex items-center gap-1 text-sm text-muted">
        <ChevronLeft className="h-4 w-4" /> Geri
      </button>
      <h1 className="text-lg font-semibold">{mode === "musteri" ? "Kayıtlı müşteri girişi" : "Çalışan girişi"}</h1>
      <LoginForm mode={mode} />
      {mode === "musteri" ? (
        <p className="text-center text-sm text-muted">
          Kaydınız yok mu? <Link href="/siparis-ver" className="text-brand">Sipariş verirken kayıt olun</Link>
        </p>
      ) : null}
    </div>
  );
}

export default function LoginPage() {
  return (
    <main className="flex min-h-dvh items-center justify-center p-4">
      <Card className="w-full max-w-md p-6">
        <div className="mb-6 text-center">
          <div className="text-3xl font-bold tracking-tight text-brand">ALKASU</div>
          <div className="text-sm text-muted">Alay Ticaret · Su ve damacana</div>
        </div>
        <Suspense>
          <Entry />
        </Suspense>
      </Card>
    </main>
  );
}
