"use client";
import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Minus, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { formatTRY, fromKurus, parseAmount, todayISO, toKurus } from "@/lib/format";
import { priceFor, searchKey } from "@/lib/catalog";
import { PRICE_LISTS, type PriceList } from "@/lib/roles";
import type { Assignee, Dealer, OrderCustomer, OrderProduct } from "@/lib/orders";
import Link from "next/link";
import { Search, X } from "lucide-react";
import { CartBar, ShopCatalog, ShopGrid, type Qty } from "@/components/shop/shop-catalog";
import { staffItems } from "@/lib/staff-catalog";

export interface OrderFormValue {
  id: string;
  customerId: string | null;
  deliveryDate: string;
  assignee: string | null;
  address: string;
  note: string;
  items: { productId: string; unitId: string; qty: number; unitPrice: number | null }[];
}

interface Line {
  key: string;
  productId: string;
  unitId: string;
  qty: number;
  /** Yalnızca yöneticinin elle girdiği fiyat; boşsa müşterinin listesinden gelir */
  manualPrice: string;
}

export function OrderForm({
  products,
  customers,
  assignees,
  initial,
  fixedCustomer,
  isNew,
  dealerMode,
}: {
  products: OrderProduct[];
  customers: OrderCustomer[];
  assignees: Assignee[];
  initial: OrderFormValue | null;
  /** Bayi kullanıcısı: müşteri kendisidir */
  fixedCustomer: OrderCustomer | null;
  isNew: boolean;
  /** Bayi: kendi alımı veya kendi müşterisine sipariş; teslim eden seçilir (D-060) */
  dealerMode?: { me: OrderCustomer; dealers: Dealer[] };
}) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const isAdmin = ctx.role === "yonetici";
  const isDealer = ctx.role === "bayi" || ctx.role === "musteri"; // kendi adına sipariş veren: atama yok
  const [id] = useState(() => initial?.id ?? crypto.randomUUID());
  const [customerId, setCustomerId] = useState<string | null>(fixedCustomer?.id ?? initial?.customerId ?? dealerMode?.me.id ?? null);
  const [deliverBy, setDeliverBy] = useState<string>("self");
  const [custQuery, setCustQuery] = useState("");
  const [deliveryDate, setDeliveryDate] = useState(initial?.deliveryDate ?? todayISO());
  const [assignee, setAssignee] = useState<string | null>(initial?.assignee ?? null);
  const [assigneeTouched, setAssigneeTouched] = useState(!isNew);
  const [address, setAddress] = useState(initial?.address ?? fixedCustomer?.address ?? "");
  const [note, setNote] = useState(initial?.note ?? "");
  const [lines, setLines] = useState<Line[]>(() => {
    const startCustomer = fixedCustomer ?? customers.find((c) => c.id === initial?.customerId);
    const startList: PriceList = startCustomer?.priceList ?? "perakende";
    return (
      initial?.items.map((i) => {
        const u = products.find((p) => p.id === i.productId)?.units.find((x) => x.id === i.unitId);
        const lp = u ? priceFor(u, startList, startCustomer?.specialPrices) : null;
        // Yöneticinin daha önce elle verdiği fiyat korunur
        const manual = ctx.role === "yonetici" && i.unitPrice !== null && i.unitPrice !== lp ? String(i.unitPrice).replace(".", ",") : "";
        return { key: crypto.randomUUID(), productId: i.productId, unitId: i.unitId, qty: i.qty, manualPrice: manual };
      }) ?? []
    );
  });
  const [prodQuery, setProdQuery] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const allCustomers = fixedCustomer ? [fixedCustomer] : customers;
  const customer = allCustomers.find((c) => c.id === customerId) ?? null;
  const list: PriceList = customer?.priceList ?? "perakende";
  const special = customer?.specialPrices;
  const byId = useMemo(() => new Map(products.map((p) => [p.id, p])), [products]);

  const custMatches = useMemo(() => {
    const k = searchKey(custQuery.trim());
    if (!k) return dealerMode ? customers.slice(0, 20) : [];
    return customers.filter((c) => searchKey(`${c.name} ${c.code}`).includes(k)).slice(0, 8);
  }, [customers, custQuery, dealerMode]);
  const ownPurchase = !!dealerMode && customerId === dealerMode.me.id;
  const needsApproval = !!dealerMode && isNew && (ownPurchase || deliverBy !== "self");
  /** Mağaza görünümü (W-13): her fiyatlı birim bir kart, fiyat seçili müşteriye göre */
  const items = useMemo(() => staffItems(products, (u) => priceFor(u, list, special)), [products, list, special]);
  const foundItems = useMemo(() => {
    const k = searchKey(prodQuery.trim());
    return k ? items.filter((i) => searchKey(`${i.productName} ${i.productCode} ${i.brand ?? ""}`).includes(k)).slice(0, 60) : [];
  }, [items, prodQuery]);
  const qty: Qty = useMemo(() => {
    const m: Qty = {};
    for (const l of lines) m[l.unitId] = (m[l.unitId] ?? 0) + l.qty;
    return m;
  }, [lines]);

  function pickCustomer(c: OrderCustomer) {
    setCustomerId(c.id);
    setCustQuery("");
    if (!address.trim() || address === (customer?.address ?? "")) setAddress(c.address ?? "");
    if (!assigneeTouched) setAssignee(c.defaultAssignee);
  }

  /** Karttaki + / − (W-13) */
  function onStep(unitId: string, d: number) {
    const item = items.find((i) => i.unitId === unitId);
    if (!item) return;
    setLines((ls) => {
      const i = ls.findIndex((l) => l.unitId === unitId);
      if (i < 0) return d > 0 ? [...ls, { key: crypto.randomUUID(), productId: item.productId, unitId, qty: d, manualPrice: "" }] : ls;
      const n = (ls[i]?.qty ?? 0) + d;
      return n <= 0 ? ls.filter((_, j) => j !== i) : ls.map((l, j) => (j === i ? { ...l, qty: n } : l));
    });
  }
  const update = (key: string, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const priced = lines.map((l) => {
    const p = byId.get(l.productId);
    const u = p?.units.find((x) => x.id === l.unitId);
    const listPrice = u ? priceFor(u, list, special) : null;
    const manual = isAdmin && l.manualPrice.trim() !== "" ? parseAmount(l.manualPrice) : null;
    const price = manual ?? listPrice;
    return { ...l, product: p, unit: u, listPrice, price, totalK: price === null ? 0 : toKurus(price * l.qty) };
  });
  const totalK = priced.reduce((s, l) => s + l.totalK, 0);
  const containers = priced.filter((l) => l.product?.deposit !== null && l.product?.deposit !== undefined).reduce((s, l) => s + l.qty * (l.unit?.factor ?? 1), 0);

  let validation: string | null = null;
  if (!customer) validation = "Müşteri seçin";
  else if (priced.length === 0) validation = "Siparişe ürün ekleyin";
  else if (priced.some((l) => l.qty <= 0 || !Number.isInteger(l.qty))) validation = "Miktarlar pozitif tam sayı olmalı";
  else if (priced.some((l) => l.price === null)) validation = "Fiyatı tanımlı olmayan ürün var";
  else if (priced.some((l) => l.price !== null && l.price < 0)) validation = "Fiyat negatif olamaz";

  async function save() {
    if (validation) return setError(validation);
    setSaving(true);
    setError(null);
    const { data, error } = await supabaseBrowser().rpc("save_order", {
      p_business: ctx.businessId,
      p: {
        id,
        customer_id: customerId,
        delivery_date: deliveryDate,
        assignee: isDealer ? null : assignee,
        deliver_by: dealerMode && isNew && !ownPurchase ? deliverBy : undefined,
        address,
        note,
        items: priced.map((l) => ({
          product_id: l.productId,
          unit_id: l.unitId,
          qty: l.qty,
          unit_price: isAdmin && l.manualPrice.trim() !== "" ? parseAmount(l.manualPrice) : null,
        })),
      },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    const no = (data as { no?: number } | null)?.no;
    toast(isNew ? `Sipariş #${no ?? ""} oluşturuldu` : "Sipariş güncellendi", "ok");
    router.push(`/siparisler/${id}`);
    router.refresh();
  }

  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_380px]">
      <div className="space-y-4">
        <Card className="space-y-3">
          {fixedCustomer ? (
            <div>
              <div className="text-sm text-muted">Sipariş veren</div>
              <div className="font-semibold">{fixedCustomer.name}</div>
            </div>
          ) : customer ? (
            <div className="flex items-center justify-between gap-2">
              <div>
                <div className="text-sm text-muted">Müşteri</div>
                <div className="font-semibold">
                  {ownPurchase ? `Kendi alımım (${customer.name})` : customer.name} <span className="text-sm font-normal text-muted">{customer.code}</span>
                </div>
                {customer.priceList !== "perakende" ? <Badge tone="ok">{PRICE_LISTS[customer.priceList]} fiyatı</Badge> : null}
              </div>
              {isNew || !dealerMode ? <Button variant="ghost" size="sm" onClick={() => setCustomerId(null)}>Değiştir</Button> : null}
            </div>
          ) : (
            <Field label="Müşteri" hint="Ad veya koddan arayın">
              <Input autoFocus value={custQuery} onChange={(e) => setCustQuery(e.target.value)} placeholder="Örn. Çelik Halat" />
              {custMatches.length ? (
                <div className="mt-1 divide-y divide-border rounded-xl border border-border">
                  {custMatches.map((c) => (
                    <button key={c.id} type="button" className="flex w-full items-center justify-between px-3 py-2 text-left hover:bg-surface-2" onClick={() => pickCustomer(c)}>
                      <span>{c.name} <span className="text-xs text-muted">{c.code}</span></span>
                      {c.priceList !== "perakende" ? <Badge tone="ok">{PRICE_LISTS[c.priceList]}</Badge> : null}
                    </button>
                  ))}
                </div>
              ) : custQuery.trim().length >= 2 ? (
                <div className="mt-1 text-sm text-muted">
                  Bulunamadı. {dealerMode ? <Link href="/musterilerim" className="text-brand">Müşterilerim bölümünden yeni müşteri ekleyin.</Link> : "Yeni müşteriyi Müşteriler bölümünden ekleyin."}
                </div>
              ) : null}
            </Field>
          )}
          {dealerMode && isNew && customer ? (
            ownPurchase ? (
              <Alert tone="warn">Bizden alımınız merkez tarafından teslim edilir; siparişiniz onaylandıktan sonra işleme alınır.</Alert>
            ) : (
              <div className="space-y-2">
                <div className="text-sm font-medium">Teslim eden</div>
                <div className="grid gap-2 sm:grid-cols-2">
                  {[{ id: "self", label: "Ben teslim ederim", hint: "Onaysız açılır" },
                    { id: "merkez", label: "Merkez (Alay Ticaret)", hint: "Onay gerekir" },
                    ...dealerMode.dealers.filter((d) => d.id !== dealerMode.me.id).map((d) => ({ id: d.id, label: d.name, hint: "Onay gerekir" }))].map((o) => (
                    <button
                      key={o.id}
                      type="button"
                      onClick={() => setDeliverBy(o.id)}
                      className={`rounded-xl border px-3 py-2 text-left ${deliverBy === o.id ? "border-brand bg-brand-soft" : "border-border"}`}
                    >
                      <span className="block font-medium">{o.label}</span>
                      <span className="block text-xs text-muted">{o.hint}</span>
                    </button>
                  ))}
                </div>
              </div>
            )
          ) : null}
        </Card>

        <section className="space-y-3" aria-label="Ürün seç">
          <div className="relative">
            <Search className="pointer-events-none absolute top-1/2 left-3 h-5 w-5 -translate-y-1/2 text-muted" />
            <Input value={prodQuery} onChange={(e) => setProdQuery(e.target.value)} placeholder="Ürün ara (ad, kod, marka)" className="h-12 pr-10 pl-10 text-base" autoComplete="off" enterKeyHint="search" />
            {prodQuery ? (
              <button type="button" className="absolute top-1/2 right-3 -translate-y-1/2 text-muted" onClick={() => setProdQuery("")} aria-label="Aramayı temizle">
                <X className="h-5 w-5" />
              </button>
            ) : null}
          </div>
          {prodQuery.trim() ? <ShopGrid items={foundItems} qty={qty} onStep={onStep} /> : <ShopCatalog items={items} qty={qty} onStep={onStep} staff />}
        </section>

        <Card id="secilenler" className="scroll-mt-16 space-y-3">
          <h2 className="font-semibold">Seçilen ürünler{priced.length ? ` (${priced.length})` : ""}</h2>
          {priced.length === 0 ? <div className="text-sm text-muted">Yukarıdan ürün seçin: kartlardaki + ile ekleyin.</div> : null}
          {priced.map((l) => (
            <div key={l.key} className="rounded-xl border border-border p-2">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0 font-medium">{l.product?.name ?? "?"}</div>
                <Button variant="ghost" size="icon" aria-label="Sil" onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))}>
                  <Trash2 className="h-4 w-4" />
                </Button>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Select className="h-10 w-36" value={l.unitId} onChange={(e) => update(l.key, { unitId: e.target.value, manualPrice: "" })}>
                  {(l.product?.units ?? []).filter((u) => priceFor(u, list, special) !== null || u.id === l.unitId).map((u) => (
                    <option key={u.id} value={u.id}>{u.name}{u.factor > 1 ? ` (${u.factor})` : ""}</option>
                  ))}
                </Select>
                <div className="flex items-center">
                  <Button variant="secondary" size="icon" aria-label="Azalt" onClick={() => update(l.key, { qty: Math.max(1, l.qty - 1) })}><Minus className="h-4 w-4" /></Button>
                  <Input
                    inputMode="numeric"
                    className="num mx-1 h-11 w-20 text-center"
                    value={String(l.qty)}
                    onChange={(e) => update(l.key, { qty: Number.parseInt(e.target.value.replace(/\D/g, "") || "0", 10) })}
                  />
                  <Button variant="secondary" size="icon" aria-label="Artır" onClick={() => update(l.key, { qty: l.qty + 1 })}><Plus className="h-4 w-4" /></Button>
                </div>
                {isAdmin ? (
                  <Input
                    inputMode="decimal"
                    className="num h-10 w-28 text-right"
                    placeholder={l.listPrice !== null ? String(l.listPrice).replace(".", ",") : "Fiyat"}
                    value={l.manualPrice}
                    onChange={(e) => update(l.key, { manualPrice: e.target.value })}
                    aria-label="Birim fiyat"
                  />
                ) : (
                  <span className="num text-sm text-muted">{l.price !== null ? formatTRY(l.price) : "Fiyat yok"} / {l.unit?.name}</span>
                )}
                <span className="num ml-auto font-semibold">{formatTRY(fromKurus(l.totalK))}</span>
              </div>
            </div>
          ))}
        </Card>
      </div>

      <div className="space-y-4">
        <Card className="space-y-3">
          <Field label="Teslim tarihi">
            <Input type="date" min={isDealer ? todayISO() : undefined} value={deliveryDate} onChange={(e) => setDeliveryDate(e.target.value)} />
          </Field>
          {!isDealer ? (
            <Field label="Teslim edecek kişi" hint="Siparişi yalnızca bu kişi veya yönetici kapatabilir">
              <Select value={assignee ?? ""} onChange={(e) => { setAssignee(e.target.value || null); setAssigneeTouched(true); }}>
                <option value="">{customer?.defaultAssignee ? "Müşterinin varsayılan sorumlusu" : "Atanmadı"}</option>
                {assignees.map((a) => <option key={a.user_id} value={a.user_id}>{a.display_name}</option>)}
              </Select>
            </Field>
          ) : null}
          <Field label="Teslimat adresi"><Textarea value={address} onChange={(e) => setAddress(e.target.value)} /></Field>
          <Field label="Not"><Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Örn. sabah 10'dan önce" /></Field>
        </Card>
        <Card id="siparis-ozet" className="scroll-mt-16 space-y-2">
          <div className="flex justify-between"><span className="text-muted">Ürün tutarı</span><span className="num font-semibold">{formatTRY(fromKurus(totalK))}</span></div>
          {containers > 0 ? <div className="text-xs text-muted">{containers} depozitolu kap · depozito teslimatta alınan boşa göre hesaplanır</div> : null}
          {error ? <Alert>{error}</Alert> : null}
          <Button size="lg" className="w-full" loading={saving} disabled={!!validation} onClick={() => void save()}>
            {isNew ? (needsApproval ? "Onaya gönder" : "Siparişi kaydet") : "Siparişi güncelle"}
          </Button>
          {validation ? <div className="text-center text-xs text-muted">{validation}</div> : null}
        </Card>
      </div>
      <div className="pb-24 lg:hidden" aria-hidden />
      <div className="lg:hidden">
        <CartBar
          count={priced.reduce((n, l) => n + l.qty, 0)}
          totalK={totalK}
          label="Devam"
          inApp
          onConfirm={() => document.getElementById("secilenler")?.scrollIntoView({ behavior: "smooth", block: "start" })}
        />
      </div>
    </div>
  );
}
