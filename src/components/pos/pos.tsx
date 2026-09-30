"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Minus, Plus, ScanLine, Search, Trash2, User, UserX, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/field";
import { Badge } from "@/components/ui/card";
import { useToast } from "@/components/ui/toast";
import { useAppContext } from "@/components/shell/context";
import { cn } from "@/lib/cn";
import { computeCart, type CartLine, type ContainerBalances } from "@/lib/cart";
import { searchKey, type CatalogProduct, type PosCustomer, type PosData, loadPosData } from "@/lib/catalog";
import { formatNumber, formatTRY, fromKurus } from "@/lib/format";
import { loadCache, saveCache } from "@/lib/offline/queue";
import { supabaseBrowser } from "@/lib/supabase/client";
import { CustomerPicker } from "./customer-picker";
import { PaymentDialog, type SaleResult } from "./payment-dialog";
import { ReceiptDialog } from "./receipt-dialog";

const CACHE_KEY = (b: string) => `pos:${b}`;

export function Pos({ initial }: { initial: PosData }) {
  const ctx = useAppContext();
  const toast = useToast();
  const [data, setData] = useState<PosData>(initial);
  const [query, setQuery] = useState("");
  const [cart, setCart] = useState<CartLine[]>([]);
  const [customer, setCustomer] = useState<PosCustomer | null>(null);
  const [empties, setEmpties] = useState<Record<string, number>>({});
  const [billDiscount, setBillDiscount] = useState(0);
  const [pickCustomer, setPickCustomer] = useState(false);
  const [paying, setPaying] = useState(false);
  const [receipt, setReceipt] = useState<SaleResult | null>(null);
  const [cartOpen, setCartOpen] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);

  // Çevrimdışı açılış için katalog önbelleği
  useEffect(() => {
    void saveCache(CACHE_KEY(ctx.businessId), initial);
  }, [initial, ctx.businessId]);
  useEffect(() => {
    if (initial.products.length === 0) {
      void loadCache<PosData>(CACHE_KEY(ctx.businessId)).then((c) => c && setData(c.value));
    }
  }, [initial.products.length, ctx.businessId]);

  const refresh = useCallback(async () => {
    try {
      const fresh = await loadPosData(supabaseBrowser(), ctx.businessId);
      setData(fresh);
      void saveCache(CACHE_KEY(ctx.businessId), fresh);
    } catch {
      /* çevrimdışı: önbellekteki veriyle devam */
    }
  }, [ctx.businessId]);

  const byId = useMemo(() => new Map(data.products.map((p) => [p.id, p])), [data.products]);
  const byBarcode = useMemo(() => {
    const m = new Map<string, { product: CatalogProduct; unitId: string | null }>();
    for (const p of data.products) for (const b of p.barcodes) m.set(b.barcode, { product: p, unitId: b.unitId });
    return m;
  }, [data.products]);

  const filtered = useMemo(() => {
    const q = searchKey(query.trim());
    const list = q
      ? data.products.filter((p) => searchKey(`${p.name} ${p.code} ${p.brand ?? ""}`).includes(q) || p.barcodes.some((b) => b.barcode.startsWith(query.trim())))
      : [...data.products].sort((a, b) => b.sold - a.sold || a.name.localeCompare(b.name, "tr"));
    return list.slice(0, 60);
  }, [data.products, query]);

  const balances: ContainerBalances = useMemo(() => {
    const m: ContainerBalances = {};
    for (const c of data.containers) if (c.customerId === (customer?.id ?? null)) m[c.productId] = { qty: c.qty, amount: c.amount };
    return m;
  }, [data.containers, customer]);

  const totals = useMemo(() => computeCart(cart, billDiscount, empties, balances), [cart, billDiscount, empties, balances]);
  const itemCount = cart.reduce((s, l) => s + l.qty, 0);

  function addProduct(p: CatalogProduct, unitId?: string | null) {
    const unit = p.units.find((u) => u.id === unitId && u.price !== null) ?? p.units.find((u) => u.price !== null);
    if (!unit || unit.price === null) return toast(`${p.name} için satış fiyatı tanımlı değil`, "danger");
    setCart((c) => {
      const i = c.findIndex((l) => l.productId === p.id && l.unitId === unit.id);
      if (i >= 0) return c.map((l, j) => (j === i ? { ...l, qty: l.qty + 1 } : l));
      return [
        ...c,
        {
          key: crypto.randomUUID(),
          productId: p.id,
          productName: p.name,
          unitId: unit.id,
          unitName: unit.name,
          factor: unit.factor,
          qty: 1,
          unitPrice: unit.price as number,
          lineDiscount: 0,
          depositAmount: p.deposit,
          emptyProductId: p.emptyProductId,
        },
      ];
    });
    if (navigator.vibrate) navigator.vibrate(15);
  }

  function onSearchEnter() {
    const q = query.trim();
    if (!q) return;
    const hit = byBarcode.get(q);
    if (hit) {
      addProduct(hit.product, hit.unitId);
      setQuery("");
      return;
    }
    if (filtered.length === 1 && filtered[0]) {
      addProduct(filtered[0]);
      setQuery("");
      return;
    }
    toast("Barkod bulunamadı", "danger");
  }

  function setUnit(key: string, unitId: string) {
    setCart((c) =>
      c.map((l) => {
        if (l.key !== key) return l;
        const u = byId.get(l.productId)?.units.find((x) => x.id === unitId);
        if (!u || u.price === null) return l;
        return { ...l, unitId: u.id, unitName: u.name, factor: u.factor, unitPrice: u.price };
      }),
    );
  }
  const setQty = (key: string, qty: number) =>
    setCart((c) => (qty <= 0 ? c.filter((l) => l.key !== key) : c.map((l) => (l.key === key ? { ...l, qty } : l))));
  const setPrice = (key: string, price: number) => setCart((c) => c.map((l) => (l.key === key ? { ...l, unitPrice: price } : l)));

  function reset() {
    setCart([]);
    setCustomer(null);
    setEmpties({});
    setBillDiscount(0);
    setQuery("");
    setCartOpen(false);
  }

  function onCompleted(r: SaleResult) {
    setPaying(false);
    setReceipt(r);
    reset();
    void refresh();
  }

  const cartView = (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between gap-2 border-b border-border p-3">
        <button
          onClick={() => setPickCustomer(true)}
          className={cn("flex min-w-0 flex-1 items-center gap-2 rounded-xl border px-3 py-2 text-left", customer ? "border-brand bg-brand-soft" : "border-border")}
        >
          <User className="h-5 w-5 shrink-0" />
          <span className="min-w-0 truncate">
            {customer ? (
              <>
                <span className="font-medium">{customer.name}</span>
                <span className="block text-xs text-muted">
                  Bakiye {formatTRY(customer.balance)} · Limit {customer.unlimited ? "limitsiz" : formatTRY(customer.creditLimit)}
                </span>
              </>
            ) : (
              <span className="text-muted">Perakende müşteri · müşteri seç</span>
            )}
          </span>
        </button>
        {customer ? (
          <Button variant="ghost" size="icon" onClick={() => setCustomer(null)} aria-label="Müşteriyi kaldır">
            <UserX className="h-5 w-5" />
          </Button>
        ) : null}
      </div>

      <div className="flex-1 space-y-2 overflow-y-auto p-3">
        {cart.length === 0 ? <div className="py-10 text-center text-muted">Sepet boş. Ürüne dokunun veya barkod okutun.</div> : null}
        {totals.lines.map((l) => {
          const p = byId.get(l.productId);
          const sellable = p?.units.filter((u) => u.price !== null) ?? [];
          return (
            <div key={l.key} className="rounded-xl border border-border p-2">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <div className="truncate font-medium">{l.productName}</div>
                  {ctx.role === "yonetici" ? (
                    <PriceEditor value={l.unitPrice} onChange={(v) => setPrice(l.key, v)} unit={l.unitName} />
                  ) : (
                    <div className="num text-xs text-muted">
                      {formatTRY(l.unitPrice)} / {l.unitName}
                    </div>
                  )}
                </div>
                <div className="num text-right font-semibold">{formatTRY(fromKurus(l.grossK))}</div>
              </div>
              <div className="mt-2 flex items-center justify-between gap-2">
                <div className="flex flex-wrap gap-1">
                  {sellable.length > 1
                    ? sellable.map((u) => (
                        <button
                          key={u.id}
                          onClick={() => setUnit(l.key, u.id)}
                          className={cn("rounded-lg px-2.5 py-1.5 text-sm", u.id === l.unitId ? "bg-brand text-white" : "bg-surface-2")}
                        >
                          {u.name}
                          {u.factor > 1 ? <span className="opacity-70"> ×{u.factor}</span> : null}
                        </button>
                      ))
                    : <span className="text-sm text-muted">{l.unitName}</span>}
                </div>
                <div className="flex items-center gap-1">
                  <Button variant="secondary" size="icon" className="h-9 w-9" onClick={() => setQty(l.key, l.qty - 1)} aria-label="Azalt">
                    {l.qty === 1 ? <Trash2 className="h-4 w-4" /> : <Minus className="h-4 w-4" />}
                  </Button>
                  <input
                    className="num h-9 w-12 rounded-lg border border-border bg-surface text-center"
                    inputMode="numeric"
                    value={l.qty}
                    onChange={(e) => {
                      const n = parseInt(e.target.value.replace(/\D/g, ""), 10);
                      setQty(l.key, Number.isFinite(n) ? n : 0);
                    }}
                    aria-label="Miktar"
                  />
                  <Button variant="secondary" size="icon" className="h-9 w-9" onClick={() => setQty(l.key, l.qty + 1)} aria-label="Arttır">
                    <Plus className="h-4 w-4" />
                  </Button>
                </div>
              </div>
            </div>
          );
        })}

        {totals.deposits.map((d) => (
          <div key={d.productId} className="rounded-xl border border-brand/40 bg-brand-soft p-3">
            <div className="text-sm font-medium">{d.productName}: boş kap</div>
            <div className="mt-2 flex items-center justify-between gap-2">
              <span className="text-sm">Getirilen boş</span>
              <div className="flex items-center gap-1">
                <Button variant="secondary" size="icon" className="h-9 w-9" onClick={() => setEmpties((e) => ({ ...e, [d.productId]: Math.max(0, d.emptyReturned - 1) }))} aria-label="Azalt">
                  <Minus className="h-4 w-4" />
                </Button>
                <span className="num w-10 text-center font-semibold">{d.emptyReturned}</span>
                <Button variant="secondary" size="icon" className="h-9 w-9" onClick={() => setEmpties((e) => ({ ...e, [d.productId]: d.emptyReturned + 1 }))} aria-label="Arttır">
                  <Plus className="h-4 w-4" />
                </Button>
              </div>
            </div>
            <div className="mt-1 text-xs">
              {d.net > 0
                ? `${d.net} kap müşteride kalacak · depozito ${formatTRY(fromKurus(d.amountK))}`
                : d.net < 0
                  ? `${-d.net} fazla boş · depozito iadesi ${formatTRY(fromKurus(-d.amountK))}`
                  : "Boşlar eksiksiz getirildi, depozito yok"}
            </div>
            {d.error ? <div className="mt-1 text-xs text-danger">{d.error}</div> : null}
          </div>
        ))}
      </div>

      <div className="safe-bottom space-y-2 border-t border-border p-3">
        <div className="num flex justify-between text-sm text-muted">
          <span>Ürünler</span>
          <span>{formatTRY(fromKurus(totals.goodsNetK))}</span>
        </div>
        {totals.depositK !== 0 ? (
          <div className="num flex justify-between text-sm text-muted">
            <span>Depozito</span>
            <span>{formatTRY(fromKurus(totals.depositK))}</span>
          </div>
        ) : null}
        <div className="num flex justify-between text-xl font-bold">
          <span>Toplam</span>
          <span>{formatTRY(fromKurus(totals.grandK))}</span>
        </div>
        <div className="flex gap-2">
          <Button variant="secondary" onClick={reset} disabled={cart.length === 0}>
            Temizle
          </Button>
          <Button size="lg" className="flex-1" disabled={cart.length === 0 || totals.errors.length > 0} onClick={() => setPaying(true)}>
            Ödeme al
          </Button>
        </div>
        {totals.errors.length > 0 ? <div className="text-xs text-danger">{totals.errors[0]}</div> : null}
      </div>
    </div>
  );

  return (
    <div className="-mx-3 -mt-3 md:-mx-6 md:grid md:h-[calc(100dvh-3rem)] md:grid-cols-[1fr_380px]">
      {/* Ürünler */}
      <section className="flex min-h-0 flex-col">
        <div className="sticky top-12 z-20 bg-bg p-3 md:top-0">
          <div className="relative">
            <Search className="pointer-events-none absolute top-3 left-3 h-5 w-5 text-muted" />
            <Input
              ref={searchRef}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  onSearchEnter();
                }
              }}
              placeholder="Ürün ara veya barkod okut"
              className="h-12 pr-10 pl-10 text-base"
              autoComplete="off"
              enterKeyHint="search"
            />
            {query ? (
              <button className="absolute top-3 right-3 text-muted" onClick={() => setQuery("")} aria-label="Temizle">
                <X className="h-5 w-5" />
              </button>
            ) : (
              <ScanLine className="pointer-events-none absolute top-3 right-3 h-5 w-5 text-muted" />
            )}
          </div>
        </div>
        <div className="grid grid-cols-2 gap-2 px-3 pb-32 sm:grid-cols-3 md:overflow-y-auto md:pb-4 lg:grid-cols-4">
          {filtered.map((p) => {
            const base = p.units.find((u) => u.price !== null);
            const inCart = cart.filter((l) => l.productId === p.id).reduce((s, l) => s + l.qty, 0);
            return (
              <button
                key={p.id}
                onClick={() => addProduct(p)}
                className={cn(
                  "relative flex min-h-24 flex-col justify-between rounded-2xl border bg-surface p-3 text-left active:scale-[0.98]",
                  inCart ? "border-brand" : "border-border",
                )}
              >
                <span className="line-clamp-2 text-[15px] leading-tight font-medium">{p.name}</span>
                <span className="mt-2 flex items-end justify-between gap-1">
                  <span className="num text-sm font-semibold">{base ? formatTRY(base.price) : "—"}</span>
                  <span className={cn("num text-xs", p.stock <= 0 ? "text-danger" : "text-muted")}>
                    {formatNumber(p.stock)} {p.baseUnit.toLocaleLowerCase("tr-TR")}
                  </span>
                </span>
                {inCart ? <Badge tone="brand" className="absolute -top-2 -right-1">{inCart}</Badge> : null}
              </button>
            );
          })}
          {filtered.length === 0 ? <div className="col-span-full py-10 text-center text-muted">Ürün bulunamadı</div> : null}
        </div>
      </section>

      {/* Sepet: masaüstünde sağ sütun */}
      <aside className="hidden min-h-0 border-l border-border bg-surface md:block">{cartView}</aside>

      {/* Sepet: mobilde alt çubuk + tam ekran */}
      {cart.length > 0 && !cartOpen ? (
        <button
          onClick={() => setCartOpen(true)}
          className="fixed inset-x-3 bottom-[76px] z-30 flex items-center justify-between rounded-2xl bg-brand px-4 py-4 text-white shadow-lg md:hidden"
        >
          <span className="font-medium">{itemCount} ürün · Sepeti aç</span>
          <span className="num text-lg font-bold">{formatTRY(fromKurus(totals.grandK))}</span>
        </button>
      ) : null}
      {cartOpen ? (
        <div className="fixed inset-0 z-50 flex flex-col bg-surface md:hidden">
          <div className="flex items-center justify-between border-b border-border px-3 py-2">
            <span className="font-semibold">Sepet</span>
            <Button variant="ghost" onClick={() => setCartOpen(false)}>
              Ürün ekle
            </Button>
          </div>
          <div className="min-h-0 flex-1">{cartView}</div>
        </div>
      ) : null}

      <CustomerPicker
        open={pickCustomer}
        onClose={() => setPickCustomer(false)}
        customers={data.customers}
        onPick={(c) => {
          setCustomer(c);
          setPickCustomer(false);
        }}
        onCreated={(c) => {
          setData((d) => ({ ...d, customers: [...d.customers, c] }));
          setCustomer(c);
          setPickCustomer(false);
        }}
      />
      {paying ? (
        <PaymentDialog
          onClose={() => setPaying(false)}
          cart={cart}
          totals={totals}
          customer={customer}
          billDiscount={billDiscount}
          setBillDiscount={setBillDiscount}
          empties={empties}
          onCompleted={onCompleted}
        />
      ) : null}
      <ReceiptDialog result={receipt} onClose={() => { setReceipt(null); searchRef.current?.focus(); }} />
    </div>
  );
}

function PriceEditor({ value, onChange, unit }: { value: number; onChange: (v: number) => void; unit: string }) {
  const [edit, setEdit] = useState(false);
  const [text, setText] = useState(String(value).replace(".", ","));
  if (!edit)
    return (
      <button className="num text-xs text-brand underline decoration-dotted" onClick={() => { setText(String(value).replace(".", ",")); setEdit(true); }}>
        {formatTRY(value)} / {unit}
      </button>
    );
  return (
    <input
      autoFocus
      inputMode="decimal"
      className="num h-8 w-24 rounded-lg border border-brand px-2 text-sm"
      value={text}
      onChange={(e) => setText(e.target.value)}
      onBlur={() => {
        const n = Number(text.replace(/\./g, "").replace(",", "."));
        if (Number.isFinite(n) && n >= 0) onChange(Math.round(n * 100) / 100);
        setEdit(false);
      }}
      onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
    />
  );
}
