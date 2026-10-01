"use client";
import { Suspense, useState } from "react";
import { useSearchParams } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/field";
import { Alert, Card } from "@/components/ui/card";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { SITE_URL } from "@/lib/env";
import { loginEmail } from "@/lib/username";

function LoginForm() {
  const params = useSearchParams();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    const { error } = await supabaseBrowser().auth.signInWithPassword({ email: loginEmail(email), password });
    setLoading(false);
    if (error) {
      setError(/invalid login/i.test(error.message) ? "Kullanıcı adı veya şifre hatalı." : errorMessage(error));
      return;
    }
    const next = params.get("next");
    window.location.href = next && next.startsWith("/") && !next.startsWith("//") ? next : "/";
  }

  async function reset() {
    if (!email.trim()) {
      setError("Şifre sıfırlama için önce e-posta adresinizi yazın.");
      return;
    }
    if (!email.includes("@")) {
      setError("Kullanıcı adıyla giriş yapanların şifresini yönetici sıfırlar. Lütfen yöneticinize başvurun.");
      return;
    }
    setError(null);
    const { error } = await supabaseBrowser().auth.resetPasswordForEmail(email.trim(), {
      redirectTo: `${window.location.origin || SITE_URL}/auth/callback?next=/sifre`,
    });
    if (error) setError(errorMessage(error));
    else setInfo("Şifre sıfırlama bağlantısı e-posta adresinize gönderildi.");
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <Field label="Kullanıcı adı veya e-posta">
        <Input type="text" autoComplete="username" autoCapitalize="none" autoCorrect="off" spellCheck={false} required value={email} onChange={(e) => setEmail(e.target.value)} />
      </Field>
      <Field label="Şifre">
        <Input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
      </Field>
      {error ? <Alert>{error}</Alert> : null}
      {info ? <Alert tone="ok">{info}</Alert> : null}
      <Button type="submit" size="lg" className="w-full" loading={loading}>
        Giriş yap
      </Button>
      <button type="button" onClick={reset} className="w-full text-center text-sm text-brand">
        Şifremi unuttum
      </button>
    </form>
  );
}

export default function LoginPage() {
  return (
    <main className="flex min-h-dvh items-center justify-center p-4">
      <Card className="w-full max-w-sm p-6">
        <div className="mb-6 text-center">
          <div className="text-3xl font-bold tracking-tight text-brand">ALKASU</div>
          <div className="text-sm text-muted">Alay Ticaret</div>
        </div>
        <Suspense>
          <LoginForm />
        </Suspense>
      </Card>
    </main>
  );
}
