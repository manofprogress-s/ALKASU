"use client";
import { Suspense, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { BriefcaseBusiness, ChevronLeft, ChevronRight, UserRound, Zap } from "lucide-react";
import { ProductArt } from "@/components/shop/product-art";
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

/** Yeni müşteri için büyük, öne çıkan hızlı sipariş kartı (W-01) */
function QuickOrder() {
  return (
    <Link href="/siparis-ver" className="group relative block overflow-hidden rounded-3xl bg-gradient-to-br from-brand to-brand-strong p-5 text-white shadow-lg shadow-brand/25 active:scale-[0.99]">
      <ProductArt kind="damacana" color="#ffffff" className="pointer-events-none absolute -right-3 -bottom-4 h-40 w-32 opacity-90" />
      <span className="relative block max-w-[70%]">
        <span className="inline-flex items-center gap-1 rounded-full bg-white/20 px-2.5 py-0.5 text-xs font-medium">
          <Zap className="h-3.5 w-3.5" /> Üyelik gerekmez
        </span>
        <span className="mt-3 block text-2xl font-extrabold leading-tight">Hızlı sipariş ver</span>
        <span className="mt-1 block text-sm text-white/85">Suyunu seç, adresini yaz; siparişin kapına gelsin.</span>
        <span className="mt-4 inline-flex h-11 items-center gap-1 rounded-xl bg-white px-4 font-semibold text-brand shadow-sm">
          Siparişe başla <ChevronRight className="h-5 w-5 transition group-hover:translate-x-0.5" />
        </span>
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
      <div className="space-y-4">
        <QuickOrder />
        <Link href="/giris?tip=musteri" className="flex items-center gap-3 rounded-2xl border border-border bg-surface p-4 hover:bg-surface-2 active:scale-[0.99]">
          <UserRound className="h-7 w-7 shrink-0 text-brand" />
          <span className="min-w-0 flex-1">
            <span className="block font-semibold">Kayıtlı müşteri girişi</span>
            <span className="block text-sm text-muted">Telefon numaran ve şifrenle gir, siparişini tekrarla.</span>
          </span>
          <ChevronRight className="h-5 w-5 text-muted" />
        </Link>
        <div className="pt-6 text-center">
          <Link href="/giris?tip=calisan" className="inline-flex items-center gap-1 text-xs text-muted hover:text-text">
            <BriefcaseBusiness className="h-3.5 w-3.5" /> Çalışan ve bayi girişi
          </Link>
        </div>
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
        <p className="mt-6 text-center text-xs text-muted">
          <Link href="/kvkk" className="underline">Müşteri Aydınlatma Metni</Link>
        </p>
      </Card>
    </main>
  );
}
