"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Field, Input } from "@/components/ui/field";
import { Alert, Card } from "@/components/ui/card";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";

export default function SetPasswordPage() {
  const [p1, setP1] = useState("");
  const [p2, setP2] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (p1.length < 8) return setError("Şifre en az 8 karakter olmalı.");
    if (p1 !== p2) return setError("Şifreler aynı değil.");
    setLoading(true);
    const { error } = await supabaseBrowser().auth.updateUser({ password: p1 });
    setLoading(false);
    if (error) return setError(errorMessage(error));
    await supabaseBrowser().rpc("password_changed"); // R-08: ilk giriş zorunluluğu kalkar
    window.location.href = "/";
  }

  return (
    <main className="flex min-h-dvh items-center justify-center p-4">
      <Card className="w-full max-w-sm p-6">
        <h1 className="mb-2 text-xl font-semibold">Şifrenizi belirleyin</h1>
        <p className="mb-4 text-sm text-muted">Size verilen geçici şifre yerine yalnızca sizin bildiğiniz yeni bir şifre belirleyin.</p>
        <form onSubmit={submit} className="space-y-4">
          <Field label="Yeni şifre" hint="En az 8 karakter">
            <Input type="password" autoComplete="new-password" value={p1} onChange={(e) => setP1(e.target.value)} />
          </Field>
          <Field label="Yeni şifre (tekrar)">
            <Input type="password" autoComplete="new-password" value={p2} onChange={(e) => setP2(e.target.value)} />
          </Field>
          {error ? <Alert>{error}</Alert> : null}
          <Button type="submit" size="lg" className="w-full" loading={loading}>
            Kaydet ve devam et
          </Button>
        </form>
      </Card>
    </main>
  );
}
