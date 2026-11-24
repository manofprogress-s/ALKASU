"use client";
import { useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Search, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Input, Select } from "@/components/ui/field";
import { ChipBar, chipClass } from "@/components/ui/chips";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { formatTRY, parseAmount } from "@/lib/format";
import { searchKey, unitPrice } from "@/lib/catalog";
import { applyDiscount, priceChanges, priceDiff, type DiscountMode } from "@/lib/special-price";
import type { OrderProduct } from "@/lib/orders";
import type { PriceList } from "@/lib/roles";
import { cn } from "@/lib/cn";

export interface PeerCustomer { id: string; code: string; name: string; channel: string }
interface Row { unitId: string; product: string; unit: string; brand: string; normal: number | null; key: string }

const fmt = (n: number | null | undefined) => (n === null || n === undefined ? "" : String(n).replace(".", ","));

/** F-38: özel fiyat ekranı. Boş hücre = özel fiyat yok (normal fiyat geçer). Değişiklikler "Kaydet" ile tek seferde yazılır. */
export function PriceEditor({ customer, prices, products, peers, canEdit }: {
  customer: { id: string; name: string; priceList: PriceList };
  prices: Record<string, number>;
  products: OrderProduct[];
  peers: PeerCustomer[];
  canEdit: boolean;
}) {
  const router = useRouter();
  const toast = useToast();
  const [draft, setDraft] = useState<Record<string, string>>(() => Object.fromEntries(Object.entries(prices).map(([k, v]) => [k, fmt(v)])));
  const [q, setQ] = useState("");
  const [brand, setBrand] = useState<string | null>(null);
  const [onlySpecial, setOnlySpecial] = useState(Object.keys(prices).length > 0);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<DiscountMode>("tl");
  const [amount, setAmount] = useState("");
  const [copyFrom, setCopyFrom] = useState("");
  const [busy, setBusy] = useState<"save" | "copy" | null>(null);

  const rows = useMemo<Row[]>(() => {
    const out: Row[] = [];
    for (const p of products)
      for (const u of p.units) {
        const normal = unitPrice(u, customer.priceList);
        if (normal === null && prices[u.id] === undefined) continue;   // fiyatı olmayan birim (ör. adet) listelenmez
        out.push({ unitId: u.id, product: p.name, unit: u.name, brand: p.shopBrand ?? "Diğer", normal, key: searchKey(`${p.name} ${p.code} ${u.name}`) });
      }
    return out.sort((a, b) => a.product.localeCompare(b.product, "tr") || a.unit.localeCompare(b.unit, "tr"));
  }, [products, customer.priceList, prices]);
  const brands = useMemo(() => [...new Set(rows.map((r) => r.brand))].sort((a, b) => a.localeCompare(b, "tr")), [rows]);

  const parsedDraft = useMemo(() => {
    const out: Record<string, number | null> = {};
    let invalid = 0;
    for (const [k, v] of Object.entries(draft)) {
      if (v.trim() === "") { out[k] = null; continue; }
      const n = parseAmount(v);
      if (n === null || n < 0) invalid++; else out[k] = n;
    }
    return { out, invalid };
  }, [draft]);
  const changes = priceChanges(prices, parsedDraft.out);
  const visible = rows.filter((r) =>
    (!q.trim() || r.key.includes(searchKey(q.trim()))) &&
    (!brand || r.brand === brand) &&
    (!onlySpecial || (draft[r.unitId] ?? "").trim() !== "" || prices[r.unitId] !== undefined));
  const targets = sel.size ? visible.filter((r) => sel.has(r.unitId)) : visible;
  const allSelected = visible.length > 0 && visible.every((r) => sel.has(r.unitId));

  const setCell = (id: string, v: string) => setDraft((d) => ({ ...d, [id]: v }));
  function applyBulk() {
    const v = parseAmount(amount);
    if (v === null || v < 0) return toast("Geçerli bir indirim girin", "danger");
    setDraft((d) => {
      const n = { ...d };
      for (const r of targets) if (r.normal !== null) n[r.unitId] = fmt(applyDiscount(r.normal, mode, v));
      return n;
    });
    toast(`${targets.length} satıra uygulandı; kaydetmeyi unutmayın`, "ok");
  }
  function clearTargets() {
    setDraft((d) => { const n = { ...d }; for (const r of targets) n[r.unitId] = ""; return n; });
  }
  async function copy() {
    if (!copyFrom) return;
    setBusy("copy");
    const { data, error } = await supabaseBrowser().from("customer_prices").select("unit_id, price").eq("customer_id", copyFrom);
    setBusy(null);
    if (error) return toast(errorMessage(error), "danger");
    const src = (data ?? []) as { unit_id: string; price: number }[];
    if (!src.length) return toast("Seçilen müşterinin özel fiyatı yok", "danger");
    setDraft((d) => ({ ...d, ...Object.fromEntries(src.map((r) => [r.unit_id, fmt(Number(r.price))])) }));
    setOnlySpecial(true);
    toast(`${src.length} fiyat kopyalandı; kontrol edip kaydedin`, "ok");
  }
  async function save() {
    if (parsedDraft.invalid) return toast("Hatalı fiyatları düzeltin", "danger");
    setBusy("save");
    const { data, error } = await supabaseBrowser().rpc("set_customer_prices", { p_customer: customer.id, p_items: changes });
    setBusy(null);
    if (error) return toast(errorMessage(error), "danger");
    toast(`${data as number} özel fiyat kaydedildi`, "ok");
    setSel(new Set());
    router.refresh();
  }

  return (
    <div className="space-y-3 pb-24">
      {!canEdit ? <Alert tone="neutral">Özel fiyatları görüntülüyorsunuz. Değiştirmek için yöneticiden “Özel fiyat” yetkisi isteyin.</Alert> : null}

      <Card className="space-y-3">
        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-0 flex-1 basis-56">
            <Search className="pointer-events-none absolute left-3 top-2.5 h-4 w-4 text-muted" />
            <Input className="pl-9" placeholder="Ürün ara" value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" className="h-4 w-4 accent-[var(--brand)]" checked={onlySpecial} onChange={(e) => setOnlySpecial(e.target.checked)} />
            Yalnızca özel fiyatlılar
          </label>
          {peers.length ? (
            <div className="w-64 max-w-full"><Select className="h-10" value="" aria-label="Başka müşteriye geç"
              onChange={(e) => e.target.value && router.push(`/musteriler/${e.target.value}/fiyatlar`)}>
              <option value="">Başka bayi / kurumsal…</option>
              {peers.map((p) => <option key={p.id} value={p.id}>{p.channel === "bayi" ? "Bayi · " : ""}{p.name}</option>)}
            </Select></div>
          ) : null}
        </div>
        <ChipBar>
          <button type="button" className={chipClass(!brand)} onClick={() => setBrand(null)}>Tümü</button>
          {brands.map((b) => <button type="button" key={b} className={chipClass(brand === b)} onClick={() => setBrand(brand === b ? null : b)}>{b}</button>)}
        </ChipBar>

        {canEdit ? (
          <div className="space-y-2 rounded-xl bg-surface-2 p-3 text-sm">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium">{sel.size ? `Seçili ${sel.size} ürün` : `Görünen ${visible.length} ürün`}:</span>
              <span>normal fiyattan</span>
              <div className="w-20"><Input className="num h-9 text-right" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="5" aria-label="İndirim" /></div>
              <div className="w-32"><Select className="h-9" value={mode} onChange={(e) => setMode(e.target.value as DiscountMode)} aria-label="İndirim türü">
                <option value="tl">TL düşük</option>
                <option value="yuzde">% düşük</option>
              </Select></div>
              <Button size="sm" onClick={applyBulk} disabled={!targets.length}>Uygula</Button>
              <Button size="sm" variant="ghost" onClick={clearTargets} disabled={!targets.length}>Özel fiyatı temizle</Button>
            </div>
            {peers.length ? (
              <div className="flex flex-wrap items-center gap-2">
                <span>Fiyatları kopyala:</span>
                <div className="w-64 max-w-full"><Select className="h-9" value={copyFrom} onChange={(e) => setCopyFrom(e.target.value)} aria-label="Kopyalanacak müşteri">
                  <option value="">Müşteri seçin…</option>
                  {peers.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                </Select></div>
                <Button size="sm" variant="secondary" disabled={!copyFrom} loading={busy === "copy"} onClick={() => void copy()}>Kopyala</Button>
              </div>
            ) : null}
          </div>
        ) : null}
      </Card>

      <Card className="p-0">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-border text-left text-xs text-muted">
              <tr>
                {canEdit ? (
                  <th className="w-8 px-3 py-2">
                    <input type="checkbox" aria-label="Tümünü seç" className="h-4 w-4 accent-[var(--brand)]" checked={allSelected}
                      onChange={() => setSel(allSelected ? new Set() : new Set(visible.map((r) => r.unitId)))} />
                  </th>
                ) : null}
                <th className="px-3 py-2">Ürün</th>
                <th className="px-3 py-2 text-right">Normal</th>
                <th className="px-3 py-2 text-right">Özel fiyat</th>
                <th className="px-3 py-2 text-right">Fark</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {visible.map((r) => {
                const raw = draft[r.unitId] ?? "";
                const val = raw.trim() === "" ? null : parseAmount(raw);
                const bad = raw.trim() !== "" && (val === null || val < 0);
                const diff = val !== null && !bad ? priceDiff(val, r.normal) : null;
                const changed = (prices[r.unitId] ?? null) !== (raw.trim() === "" ? null : val);
                return (
                  <tr key={r.unitId} className={cn(changed && "bg-warn-soft/40")}>
                    {canEdit ? (
                      <td className="px-3 py-1.5">
                        <input type="checkbox" aria-label={`${r.product} seç`} className="h-4 w-4 accent-[var(--brand)]" checked={sel.has(r.unitId)}
                          onChange={() => setSel((s) => { const n = new Set(s); if (n.has(r.unitId)) n.delete(r.unitId); else n.add(r.unitId); return n; })} />
                      </td>
                    ) : null}
                    <td className="px-3 py-1.5">
                      <div className="font-medium">{r.product}</div>
                      <div className="text-xs text-muted">{r.unit}</div>
                    </td>
                    <td className="num px-3 py-1.5 text-right text-muted">{r.normal !== null ? formatTRY(r.normal) : "—"}</td>
                    <td className="px-3 py-1.5 text-right">
                      {canEdit ? (
                        <div className="flex items-center justify-end gap-1">
                          <div className="w-24"><Input className={cn("num h-9 text-right", bad && "border-danger")} inputMode="decimal" placeholder="—"
                            value={raw} onChange={(e) => setCell(r.unitId, e.target.value)} aria-label={`${r.product} özel fiyat`} /></div>
                          {raw ? (
                            <button type="button" className="rounded-lg p-1 text-muted hover:text-danger" aria-label="Temizle" onClick={() => setCell(r.unitId, "")}>
                              <X className="h-4 w-4" />
                            </button>
                          ) : <span className="w-6" />}
                        </div>
                      ) : <span className="num font-semibold">{val !== null ? formatTRY(val) : "—"}</span>}
                    </td>
                    <td className="num px-3 py-1.5 text-right text-xs">
                      {diff ? (
                        <Badge tone={diff.amount < 0 ? "ok" : diff.amount > 0 ? "warn" : "neutral"}>
                          {diff.amount > 0 ? "+" : ""}{formatTRY(diff.amount)} · %{Math.abs(diff.pct).toLocaleString("tr-TR")}
                        </Badge>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
              {visible.length === 0 ? (
                <tr><td colSpan={5} className="px-3 py-8 text-center text-muted">
                  {onlySpecial ? "Özel fiyat yok. “Yalnızca özel fiyatlılar” işaretini kaldırıp ürün seçin." : "Ürün bulunamadı"}
                </td></tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </Card>

      {canEdit ? (
        <div className="fixed inset-x-0 bottom-16 z-20 px-4 md:bottom-4">
          <div className="mx-auto flex max-w-3xl flex-wrap items-center justify-between gap-2 rounded-2xl border border-border bg-surface p-3 shadow-lg">
            <span className="text-sm">
              {changes.length ? <><b>{changes.length}</b> değişiklik kaydedilmedi</> : <span className="text-muted">Değişiklik yok</span>}
              {parsedDraft.invalid ? <span className="ml-2 text-danger">{parsedDraft.invalid} hatalı fiyat</span> : null}
            </span>
            <div className="flex gap-2">
              <Link href={`/musteriler/${customer.id}`} className="inline-flex h-10 items-center rounded-xl px-3 text-sm text-muted hover:text-brand">Müşteri kartı</Link>
              <Button variant="ghost" disabled={!changes.length} onClick={() => setDraft(Object.fromEntries(Object.entries(prices).map(([k, v]) => [k, fmt(v)])))}>Vazgeç</Button>
              <Button disabled={!changes.length || !!parsedDraft.invalid} loading={busy === "save"} onClick={() => void save()}>Kaydet</Button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
