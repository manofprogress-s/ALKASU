"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Field, Input, Select } from "@/components/ui/field";
import { Alert, Card } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { parseAmount } from "@/lib/format";

export interface ProductFormValue {
  id?: string;
  code: string;
  name: string;
  brand_id: string | null;
  category_id: string | null;
  base_unit_name: string;
  base_price: number | null;
  vat_rate: number;
  critical_level: number | null;
  kind: "normal" | "depozitolu" | "bos_kap";
  deposit_amount: number | null;
  empty_product_id: string | null;
  active: boolean;
  units: { id?: string; name: string; factor: number; price: number | null }[];
  barcodes: { barcode: string; unit_name: string | null }[];
}

const EMPTY: ProductFormValue = {
  code: "", name: "", brand_id: null, category_id: null, base_unit_name: "Adet", base_price: null, vat_rate: 1, critical_level: null,
  kind: "normal", deposit_amount: null, empty_product_id: null, active: true, units: [], barcodes: [],
};
const str = (n: number | null | undefined) => (n === null || n === undefined ? "" : String(n).replace(".", ","));

export function ProductForm({ initial, brands, categories, containers }: {
  initial: ProductFormValue | null;
  brands: { id: string; name: string }[];
  categories: { id: string; name: string }[];
  containers: { id: string; name: string }[];
}) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [v, setV] = useState<ProductFormValue>(initial ?? EMPTY);
  const [price, setPrice] = useState(str(v.base_price));
  const [unitPrices, setUnitPrices] = useState(v.units.map((u) => str(u.price)));
  const [dep, setDep] = useState(str(v.deposit_amount));
  const [brandList, setBrandList] = useState(brands);
  const [catList, setCatList] = useState(categories);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const set = <K extends keyof ProductFormValue>(k: K, val: ProductFormValue[K]) => setV((x) => ({ ...x, [k]: val }));

  async function addNamed(kind: "brand" | "category") {
    const name = prompt(kind === "brand" ? "Yeni marka adı" : "Yeni kategori adı")?.trim();
    if (!name) return;
    const { data, error } = await supabaseBrowser().rpc(kind === "brand" ? "upsert_brand" : "upsert_category", { p_business: ctx.businessId, p_name: name });
    if (error) return toast(errorMessage(error), "danger");
    if (kind === "brand") { setBrandList((l) => [...l, { id: data as string, name }]); set("brand_id", data as string); }
    else { setCatList((l) => [...l, { id: data as string, name }]); set("category_id", data as string); }
  }

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const basePrice = price.trim() === "" ? null : parseAmount(price);
    if (price.trim() !== "" && basePrice === null) return setError("Satış fiyatı geçersiz");
    if (v.kind === "depozitolu" && (!parseAmount(dep) || !v.empty_product_id)) return setError("Depozitolu ürün için depozito tutarı ve boş kap ürünü seçin");
    const units = v.units.map((u, i) => ({ ...u, price: unitPrices[i]?.trim() ? parseAmount(unitPrices[i] ?? "") : null }));
    if (units.some((u) => !u.name.trim() || !Number.isInteger(u.factor) || u.factor < 2)) return setError("Ek birimlerin adı ve 1'den büyük içeriği olmalı");
    setSaving(true);
    const { data, error } = await supabaseBrowser().rpc("upsert_product", {
      p_business: ctx.businessId,
      p: {
        id: v.id ?? null, code: v.code, name: v.name, brand_id: v.brand_id, category_id: v.category_id,
        base_unit_name: v.base_unit_name, base_price: v.kind === "bos_kap" ? null : basePrice, vat_rate: v.vat_rate,
        critical_level: v.critical_level, is_container: v.kind === "bos_kap",
        deposit_amount: v.kind === "depozitolu" ? parseAmount(dep) : null,
        empty_product_id: v.kind === "depozitolu" ? v.empty_product_id : null,
        active: v.active,
        units: v.kind === "bos_kap" ? [] : units,
        barcodes: v.barcodes.filter((b) => b.barcode.trim()),
      },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    toast("Ürün kaydedildi", "ok");
    router.push(v.id ? `/urunler/${data}` : "/urunler");
    router.refresh();
  }

  return (
    <form onSubmit={save} className="space-y-4">
      <Card className="grid gap-3 md:grid-cols-2">
        <Field label="Ürün kodu"><Input required value={v.code} onChange={(e) => set("code", e.target.value)} /></Field>
        <Field label="Ürün adı"><Input required value={v.name} onChange={(e) => set("name", e.target.value)} /></Field>
        <Field label="Marka" hint={<button type="button" className="text-brand" onClick={() => addNamed("brand")}>+ Yeni marka</button>}>
          <Select value={v.brand_id ?? ""} onChange={(e) => set("brand_id", e.target.value || null)}>
            <option value="">Seçin</option>
            {brandList.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </Select>
        </Field>
        <Field label="Kategori" hint={<button type="button" className="text-brand" onClick={() => addNamed("category")}>+ Yeni kategori</button>}>
          <Select value={v.category_id ?? ""} onChange={(e) => set("category_id", e.target.value || null)}>
            <option value="">Seçin</option>
            {catList.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </Select>
        </Field>
        <Field label="Ürün türü">
          <Select value={v.kind} onChange={(e) => set("kind", e.target.value as ProductFormValue["kind"])}>
            <option value="normal">Normal ürün</option>
            <option value="depozitolu">Depozitolu (dolu damacana vb.)</option>
            <option value="bos_kap">Boş kap (satılmaz, stoğu izlenir)</option>
          </Select>
        </Field>
        <Field label="KDV oranı">
          <Select value={v.vat_rate} onChange={(e) => set("vat_rate", Number(e.target.value))}>
            {[0, 1, 10, 20].map((r) => <option key={r} value={r}>%{r}</option>)}
          </Select>
        </Field>
        {v.kind === "depozitolu" ? (
          <>
            <Field label="Depozito (kap başına ₺)"><Input inputMode="decimal" value={dep} onChange={(e) => setDep(e.target.value)} /></Field>
            <Field label="Bağlı boş kap ürünü" hint={containers.length === 0 ? "Önce türü 'Boş kap' olan bir ürün oluşturun" : undefined}>
              <Select value={v.empty_product_id ?? ""} onChange={(e) => set("empty_product_id", e.target.value || null)}>
                <option value="">Seçin</option>
                {containers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </Select>
            </Field>
          </>
        ) : null}
        <Field label="Kritik stok (temel birim)" hint="Bu seviyeye inince uyarı verilir">
          <Input inputMode="numeric" value={v.critical_level ?? ""} onChange={(e) => set("critical_level", e.target.value === "" ? null : parseInt(e.target.value.replace(/\D/g, ""), 10))} />
        </Field>
        <label className="flex items-center gap-2 self-end pb-3">
          <input type="checkbox" className="h-5 w-5" checked={v.active} onChange={(e) => set("active", e.target.checked)} /> Aktif
        </label>
      </Card>

      <Card className="space-y-3">
        <h2 className="font-semibold">Birimler ve satış fiyatları (KDV dahil)</h2>
        <div className="grid grid-cols-[1fr_90px_1fr_44px] items-end gap-2">
          <Field label="Temel birim"><Input value={v.base_unit_name} onChange={(e) => set("base_unit_name", e.target.value)} /></Field>
          <Field label="İçerik"><Input value="1" disabled /></Field>
          <Field label="Fiyat ₺"><Input inputMode="decimal" disabled={v.kind === "bos_kap"} value={price} onChange={(e) => setPrice(e.target.value)} /></Field>
          <span />
          {v.kind !== "bos_kap" && v.units.map((u, i) => (
            <div key={u.id ?? i} className="contents">
              <Input value={u.name} onChange={(e) => set("units", v.units.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)))} aria-label="Birim adı" />
              <Input inputMode="numeric" value={u.factor || ""} disabled={!!u.id}
                title={u.id ? "Kullanımdaki birimin içeriği değiştirilemez; yeni birim ekleyin" : undefined}
                onChange={(e) => set("units", v.units.map((x, j) => (j === i ? { ...x, factor: parseInt(e.target.value.replace(/\D/g, ""), 10) || 0 } : x)))} aria-label="İçerik" />
              <Input inputMode="decimal" value={unitPrices[i] ?? ""} onChange={(e) => setUnitPrices((p) => p.map((x, j) => (j === i ? e.target.value : x)))} aria-label="Fiyat" />
              <Button variant="ghost" size="icon" onClick={() => { set("units", v.units.filter((_, j) => j !== i)); setUnitPrices((p) => p.filter((_, j) => j !== i)); }} aria-label="Birimi kaldır">
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          ))}
        </div>
        {v.kind !== "bos_kap" && v.units.length < 2 ? (
          <Button variant="secondary" size="sm" onClick={() => { set("units", [...v.units, { name: v.units.length ? "Koli" : "Paket", factor: 0, price: null }]); setUnitPrices((p) => [...p, ""]); }}>
            <Plus className="h-4 w-4" /> Paket / koli ekle
          </Button>
        ) : null}
        <p className="text-xs text-muted">Stok her zaman temel birimde tutulur. Fiyatı boş bırakılan birim satış ekranında seçilemez.</p>
      </Card>

      <Card className="space-y-2">
        <h2 className="font-semibold">Barkodlar</h2>
        {v.barcodes.map((b, i) => (
          <div key={i} className="grid grid-cols-[1fr_140px_44px] gap-2">
            <Input value={b.barcode} inputMode="numeric" onChange={(e) => set("barcodes", v.barcodes.map((x, j) => (j === i ? { ...x, barcode: e.target.value } : x)))} aria-label="Barkod" />
            <Select value={b.unit_name ?? ""} onChange={(e) => set("barcodes", v.barcodes.map((x, j) => (j === i ? { ...x, unit_name: e.target.value || null } : x)))} aria-label="Birim">
              <option value="">{v.base_unit_name}</option>
              {v.units.filter((u) => u.id).map((u) => <option key={u.id} value={u.name}>{u.name}</option>)}
            </Select>
            <Button variant="ghost" size="icon" onClick={() => set("barcodes", v.barcodes.filter((_, j) => j !== i))} aria-label="Barkodu kaldır"><Trash2 className="h-4 w-4" /></Button>
          </div>
        ))}
        <Button variant="secondary" size="sm" onClick={() => set("barcodes", [...v.barcodes, { barcode: "", unit_name: null }])}><Plus className="h-4 w-4" /> Barkod ekle</Button>
      </Card>

      {error ? <Alert>{error}</Alert> : null}
      <div className="flex gap-2">
        <Button variant="secondary" onClick={() => router.back()}>Vazgeç</Button>
        <Button type="submit" size="lg" className="flex-1" loading={saving}>Kaydet</Button>
      </div>
    </form>
  );
}
