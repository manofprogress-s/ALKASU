"use client";
import { useEffect, useState, useTransition } from "react";
import Link from "next/link";
import { ChevronLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Field, Input, Textarea } from "@/components/ui/field";
import { LocationField } from "@/components/geo/location-field";
import { formatTRY, fromKurus } from "@/lib/format";
import type { LatLng } from "@/lib/geo";
import type { ShopItem } from "@/lib/shop";
import { registerAndOrder } from "@/app/siparis-ver/actions";
import { MARKETING_TEXT, SHORT_NOTICE } from "@/lib/kvkk";
import { CartBar, CartButton, CartList, ShopCatalog, cartTotals, nextQty, type Qty } from "@/components/shop/shop-catalog";

/** Hızlı sipariş (yeni müşteri): 1) ürünleri seç  2) sepet + adres + bilgiler → kayıt ve sipariş tek adımda (W-02, W-08) */
export function PublicOrderForm({ items }: { items: ShopItem[] }) {
  const [qty, setQty] = useState<Qty>({});
  const [stage, setStage] = useState<"urunler" | "sepet">("urunler");
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [password, setPassword] = useState("");
  const [password2, setPassword2] = useState("");
  const [address, setAddress] = useState("");
  const [location, setLocation] = useState<LatLng | null>(null);
  const [note, setNote] = useState("");
  const [day, setDay] = useState<"bugun" | "yarin">("bugun");
  const [marketing, setMarketing] = useState(false);
  const [website, setWebsite] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [exists, setExists] = useState(false);
  const [pending, start] = useTransition();

  const { chosen, totalK, count } = cartTotals(items, qty);
  const anyDeposit = chosen.some((i) => i.hasDeposit);
  const step = (id: string, d: number) => setQty((q) => nextQty(q, id, d));
  useEffect(() => { window.scrollTo({ top: 0 }); }, [stage]);

  const validation =
    chosen.length === 0 ? "Ürün seçin"
      : name.trim().length < 3 ? "Ad soyad yazın"
        : phone.replace(/\D/g, "").length < 10 ? "Cep telefonu yazın"
          : password.length < 8 ? "Şifre en az 8 karakter olmalı"
            : password !== password2 ? "Şifreler aynı değil"
              : address.trim().length < 10 ? "Açık adres yazın"
                : null;

  function submit() {
    if (validation) return setError(validation);
    setError(null);
    setExists(false);
    start(async () => {
      const r = await registerAndOrder({
        name, phone, password, address, note, day, marketing, website,
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

  const header = (
    <div className="flex items-start justify-between gap-2">
      <div>
        <div className="text-3xl font-extrabold tracking-tight text-brand">ALKASU</div>
        <div className="text-sm text-muted">Alay Ticaret · Su ve damacana siparişi</div>
      </div>
      <div className="flex flex-col items-end gap-0.5">
        <CartButton count={count} onClick={() => count && setStage("sepet")} />
        <Link href="/giris?tip=musteri" className="px-2 text-sm text-brand">Kayıtlıyım, giriş yap</Link>
      </div>
    </div>
  );

  if (stage === "urunler") {
    return (
      <div className="space-y-4 pb-24">
        {header}
        <ShopCatalog items={items} qty={qty} onStep={step} />
        <p className="text-center text-xs text-muted">
          Fiyatlara KDV dahildir. <Link href="/kvkk" className="underline">Müşteri Aydınlatma Metni</Link>
        </p>
        <CartBar count={count} totalK={totalK} onConfirm={() => setStage("sepet")} />
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {header}
      <button type="button" onClick={() => setStage("urunler")} className="flex items-center gap-1 font-medium text-brand">
        <ChevronLeft className="h-5 w-5" /> Ürün eklemeye devam et
      </button>
      <Card className="space-y-2">
        <h2 className="text-lg font-semibold">Sepetiniz</h2>
        <CartList items={items} qty={qty} onStep={step} />
        <p className="text-xs text-muted">
          Fiyatlara KDV dahildir.{anyDeposit ? " Damacana fiyatı boş damacana değişimiyle geçerlidir; boş damacananız yoksa teslimatta depozito alınır." : ""} Kesin tutar teslimatta belirlenir.
        </p>
      </Card>

      <Card className="space-y-3">
        <h2 className="text-lg font-semibold">Teslimat adresi</h2>
        <Field label="Açık adres" hint="Mahalle, sokak, bina no, daire, kat; varsa tarif">
          <Textarea autoComplete="street-address" value={address} onChange={(e) => setAddress(e.target.value)} />
        </Field>
        <LocationField value={location} onChange={setLocation} address={address} customer />
        <div className="grid grid-cols-2 gap-2">
          <Button variant={day === "bugun" ? "primary" : "secondary"} onClick={() => setDay("bugun")}>Bugün</Button>
          <Button variant={day === "yarin" ? "primary" : "secondary"} onClick={() => setDay("yarin")}>Yarın</Button>
        </div>
        <Field label="Not (isteğe bağlı)"><Input value={note} maxLength={300} onChange={(e) => setNote(e.target.value)} placeholder="Örn. zile basmayın, öğleden sonra" /></Field>
      </Card>

      <Card className="space-y-3">
        <h2 className="text-lg font-semibold">Bilgileriniz</h2>
        <p className="text-sm text-muted">Bir sonraki siparişinizde telefonunuz ve şifrenizle giriş yapacaksınız.</p>
        <Field label="Ad soyad"><Input autoComplete="name" value={name} onChange={(e) => setName(e.target.value)} /></Field>
        <Field label="Cep telefonu"><Input type="tel" inputMode="tel" autoComplete="tel" placeholder="05xx xxx xx xx" value={phone} onChange={(e) => setPhone(e.target.value)} /></Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Şifre" hint="En az 8 karakter"><Input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
          <Field label="Şifre (tekrar)"><Input type="password" autoComplete="new-password" value={password2} onChange={(e) => setPassword2(e.target.value)} /></Field>
        </div>
        {/* Bot tuzağı: ekranda görünmez, insanlar doldurmaz */}
        <input type="text" name="website" tabIndex={-1} autoComplete="off" value={website} onChange={(e) => setWebsite(e.target.value)} className="absolute -left-[9999px] h-0 w-0 opacity-0" aria-hidden="true" />
        <div className="space-y-1 rounded-xl bg-bg p-3 text-xs text-muted">
          <p>{SHORT_NOTICE}</p>
          <p>Ayrıntılar ve haklarınız için <Link href="/kvkk" target="_blank" className="font-medium text-brand underline">Müşteri Aydınlatma Metnini görüntüleyin</Link>.</p>
        </div>
        <label className="flex items-start gap-2 text-sm">
          <input type="checkbox" className="mt-0.5 h-5 w-5 shrink-0" checked={marketing} onChange={(e) => setMarketing(e.target.checked)} />
          <span><span className="font-medium">İsteğe bağlı:</span> {MARKETING_TEXT}</span>
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
