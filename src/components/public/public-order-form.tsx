"use client";
import { useMemo, useState, useTransition } from "react";
import Link from "next/link";
import { Minus, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Field, Input, Textarea } from "@/components/ui/field";
import { LocationField } from "@/components/geo/location-field";
import { formatTRY, fromKurus, toKurus } from "@/lib/format";
import type { LatLng } from "@/lib/geo";
import { registerAndOrder } from "@/app/siparis-ver/actions";

export interface PublicItem {
  productId: string;
  productName: string;
  unitId: string;
  unitName: string;
  factor: number;
  price: number;
  hasDeposit: boolean;
}

export function PublicOrderForm({ items }: { items: PublicItem[] }) {
  const [qty, setQty] = useState<Record<string, number>>({});
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [password, setPassword] = useState("");
  const [password2, setPassword2] = useState("");
  const [address, setAddress] = useState("");
  const [location, setLocation] = useState<LatLng | null>(null);
  const [note, setNote] = useState("");
  const [day, setDay] = useState<"bugun" | "yarin">("bugun");
  const [consent, setConsent] = useState(false);
  const [website, setWebsite] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [exists, setExists] = useState(false);
  const [pending, start] = useTransition();

  const chosen = items.filter((i) => (qty[i.unitId] ?? 0) > 0);
  const totalK = chosen.reduce((s, i) => s + toKurus(i.price * (qty[i.unitId] ?? 0)), 0);
  const anyDeposit = chosen.some((i) => i.hasDeposit);
  const step = (id: string, d: number) => setQty((q) => ({ ...q, [id]: Math.max(0, Math.min(1000, (q[id] ?? 0) + d)) }));

  const validation = useMemo(() => {
    if (chosen.length === 0) return "Ürün seçin";
    if (name.trim().length < 3) return "Ad soyad yazın";
    if (phone.replace(/\D/g, "").length < 10) return "Cep telefonu yazın";
    if (password.length < 8) return "Şifre en az 8 karakter olmalı";
    if (password !== password2) return "Şifreler aynı değil";
    if (address.trim().length < 10) return "Açık adres yazın";
    if (!consent) return "Onay kutusunu işaretleyin";
    return null;
  }, [chosen.length, name, phone, password, password2, address, consent]);

  function submit() {
    if (validation) return setError(validation);
    setError(null);
    setExists(false);
    start(async () => {
      const r = await registerAndOrder({
        name, phone, password, address, note, day, consent, website,
        lat: location?.lat ?? null, lng: location?.lng ?? null,
        items: chosen.map((i) => ({ productId: i.productId, unitId: i.unitId, qty: qty[i.unitId] ?? 0 })),
      });
      if (!r.ok) {
        setExists(!!r.exists);
        return setError(r.message);
      }
      const q = new URLSearchParams({ hosgeldin: "1" });
      if (r.orderNo) q.set("siparis", String(r.orderNo));
      if (r.warning) q.set("uyari", r.warning);
      window.location.assign(`/?${q.toString()}`);
    });
  }

  return (
    <div className="space-y-4">
      <Card className="space-y-2">
        <h2 className="text-lg font-semibold">1. Ürünler</h2>
        <ul className="divide-y divide-border">
          {items.map((i) => {
            const n = qty[i.unitId] ?? 0;
            return (
              <li key={i.unitId} className="flex items-center justify-between gap-2 py-2">
                <span className="min-w-0">
                  <span className="block font-medium">{i.productName}</span>
                  <span className="num block text-sm text-muted">{formatTRY(i.price)} / {i.unitName}{i.factor > 1 ? ` (${i.factor} adet)` : ""}</span>
                </span>
                <span className="flex shrink-0 items-center">
                  <Button variant="secondary" size="icon" aria-label="Azalt" disabled={n === 0} onClick={() => step(i.unitId, -1)}><Minus className="h-4 w-4" /></Button>
                  <span className="num w-10 text-center text-lg font-semibold">{n}</span>
                  <Button variant={n ? "primary" : "secondary"} size="icon" aria-label="Artır" onClick={() => step(i.unitId, 1)}><Plus className="h-4 w-4" /></Button>
                </span>
              </li>
            );
          })}
        </ul>
        <div className="flex justify-between border-t border-border pt-2 font-semibold">
          <span>Toplam</span><span className="num">{formatTRY(fromKurus(totalK))}</span>
        </div>
        <p className="text-xs text-muted">
          Fiyatlara KDV dahildir.{anyDeposit ? " Damacana fiyatı boş damacana değişimiyle geçerlidir; boş damacananız yoksa teslimatta depozito alınır." : ""} Kesin tutar teslimatta belirlenir.
        </p>
      </Card>

      <Card className="space-y-3">
        <h2 className="text-lg font-semibold">2. Teslimat adresi</h2>
        <Field label="Açık adres" hint="Mahalle, sokak, bina no, daire, kat; varsa tarif">
          <Textarea autoComplete="street-address" value={address} onChange={(e) => setAddress(e.target.value)} />
        </Field>
        <LocationField value={location} onChange={setLocation} address={address} />
        <div className="grid grid-cols-2 gap-2">
          <Button variant={day === "bugun" ? "primary" : "secondary"} onClick={() => setDay("bugun")}>Bugün</Button>
          <Button variant={day === "yarin" ? "primary" : "secondary"} onClick={() => setDay("yarin")}>Yarın</Button>
        </div>
        <Field label="Not (isteğe bağlı)"><Input value={note} maxLength={300} onChange={(e) => setNote(e.target.value)} placeholder="Örn. zile basmayın, öğleden sonra" /></Field>
      </Card>

      <Card className="space-y-3">
        <h2 className="text-lg font-semibold">3. Bilgileriniz</h2>
        <p className="text-sm text-muted">Bir sonraki siparişinizde telefonunuz ve şifrenizle giriş yapacaksınız.</p>
        <Field label="Ad soyad"><Input autoComplete="name" value={name} onChange={(e) => setName(e.target.value)} /></Field>
        <Field label="Cep telefonu"><Input type="tel" inputMode="tel" autoComplete="tel" placeholder="05xx xxx xx xx" value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Şifre" hint="En az 8 karakter"><Input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
          <Field label="Şifre (tekrar)"><Input type="password" autoComplete="new-password" value={password2} onChange={(e) => setPassword2(e.target.value)} /></Field>
        </div>
        {/* Bot tuzağı: ekranda görünmez, insanlar doldurmaz */}
        <input type="text" name="website" tabIndex={-1} autoComplete="off" value={website} onChange={(e) => setWebsite(e.target.value)} className="absolute -left-[9999px] h-0 w-0 opacity-0" aria-hidden="true" />
        <label className="flex items-start gap-2 text-sm">
          <input type="checkbox" className="mt-0.5 h-5 w-5 shrink-0" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
          <span>Ad, telefon, adres ve konum bilgilerimin siparişimin teslimatı ve benimle iletişim amacıyla Alay Ticaret tarafından kullanılmasını kabul ediyorum.</span>
        </label>
      </Card>

      {error ? (
        <Alert>
          {error}
          {exists ? <> <Link href="/giris?tip=musteri" className="font-semibold underline">Giriş yap</Link></> : null}
        </Alert>
      ) : null}
      <Button size="lg" className="w-full" loading={pending} disabled={!!validation} onClick={submit}>
        Siparişi gönder{totalK ? ` · ${formatTRY(fromKurus(totalK))}` : ""}
      </Button>
      {validation ? <p className="text-center text-sm text-muted">{validation}</p> : (
        <p className="text-center text-sm text-muted">İlk siparişinizi telefonla teyit edip yola çıkaracağız.</p>
      )}
    </div>
  );
}
