"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { ChevronLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Field, Input, Textarea } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { addDaysISO, formatTRY, fromKurus, todayISO } from "@/lib/format";
import { SHORT_NOTICE } from "@/lib/kvkk";
import type { ShopItem } from "@/lib/shop";
import { CartBar, CartButton, CartList, ShopCatalog, cartTotals, nextQty, type Qty } from "./shop-catalog";

/** Kayıtlı müşterinin siparişi: aynı mağaza ekranı, sonra sepet + adres (W-08). Fiyat sunucuda belirlenir. */
export function CustomerShop({ items, customerId, address: initialAddress }: { items: ShopItem[]; customerId: string; address: string | null }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [qty, setQty] = useState<Qty>({});
  const [stage, setStage] = useState<"urunler" | "sepet">("urunler");
  const [address, setAddress] = useState(initialAddress ?? "");
  const [day, setDay] = useState<"bugun" | "yarin">("bugun");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [id] = useState(() => crypto.randomUUID());
  const { chosen, totalK, count } = cartTotals(items, qty);
  const anyDeposit = chosen.some((i) => i.hasDeposit);
  const step = (u: string, d: number) => setQty((q) => nextQty(q, u, d));
  useEffect(() => { window.scrollTo({ top: 0 }); }, [stage]);

  const validation = chosen.length === 0 ? "Ürün seçin" : address.trim().length < 10 ? "Açık adres yazın" : null;

  async function submit() {
    if (validation) return setError(validation);
    setSaving(true);
    setError(null);
    const today = todayISO();
    const { data, error } = await supabaseBrowser().rpc("save_order", {
      p_business: ctx.businessId,
      p: {
        id,
        customer_id: customerId,
        delivery_date: day === "yarin" ? addDaysISO(today, 1) : today,
        address,
        note: note || null,
        items: chosen.map((i) => ({ product_id: i.productId, unit_id: i.unitId, qty: qty[i.unitId] ?? 0 })),
      },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    toast(`Siparişiniz alındı (#${(data as { no?: number } | null)?.no ?? ""})`, "ok");
    router.push(`/siparisler/${id}`);
    router.refresh();
  }

  if (stage === "urunler") {
    return (
      <div className="space-y-4 pb-20">
        <div className="flex items-center justify-between gap-2">
          <h1 className="text-2xl font-bold tracking-tight">Yeni sipariş</h1>
          <CartButton count={count} onClick={() => count && setStage("sepet")} />
        </div>
        <ShopCatalog items={items} qty={qty} onStep={step} />
        <CartBar inApp count={count} totalK={totalK} onConfirm={() => setStage("sepet")} />
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      <button type="button" onClick={() => setStage("urunler")} className="flex items-center gap-1 font-medium text-brand">
        <ChevronLeft className="h-5 w-5" /> Ürün eklemeye devam et
      </button>
      <Card className="space-y-2">
        <h2 className="text-lg font-semibold">Sepetiniz</h2>
        <CartList items={items} qty={qty} onStep={step} />
        <p className="text-xs text-muted">
          Fiyatlara KDV dahildir.{anyDeposit ? " Damacana fiyatı boş damacana değişimiyle geçerlidir; boş damacananız yoksa teslimatta depozito alınır." : ""}
        </p>
      </Card>
      <Card className="space-y-3">
        <h2 className="text-lg font-semibold">Teslimat</h2>
        <Field label="Adres" hint="Farklı bir adrese istiyorsanız değiştirin"><Textarea value={address} onChange={(e) => setAddress(e.target.value)} /></Field>
        <div className="grid grid-cols-2 gap-2">
          <Button variant={day === "bugun" ? "primary" : "secondary"} onClick={() => setDay("bugun")}>Bugün</Button>
          <Button variant={day === "yarin" ? "primary" : "secondary"} onClick={() => setDay("yarin")}>Yarın</Button>
        </div>
        <Field label="Not (isteğe bağlı)"><Input value={note} maxLength={300} onChange={(e) => setNote(e.target.value)} placeholder="Örn. zile basmayın" /></Field>
      </Card>
      {error ? <Alert>{error}</Alert> : null}
      <Button size="lg" className="w-full" loading={saving} disabled={!!validation} onClick={() => void submit()}>
        Siparişi gönder{totalK ? ` · ${formatTRY(fromKurus(totalK))}` : ""}
      </Button>
      {validation ? <p className="text-center text-sm text-muted">{validation}</p> : null}
      <p className="text-xs text-muted">{SHORT_NOTICE} <Link href="/kvkk" target="_blank" className="text-brand underline">Müşteri Aydınlatma Metni</Link></p>
    </div>
  );
}
