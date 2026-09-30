"use client";
import { useState } from "react";
import { Download, FileSpreadsheet } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card, Stat } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { readWorkbook } from "@/lib/excel/read";

interface Issue { sheet?: string; row: number; field: string; message: string }
interface Result { ok: boolean; applied: boolean; errors: Issue[]; warnings: Issue[]; summary: Record<string, number> }

export function ImportWizard() {
  const ctx = useAppContext();
  const toast = useToast();
  const [file, setFile] = useState<File | null>(null);
  const [sheets, setSheets] = useState<Record<string, Record<string, string>[]> | null>(null);
  const [products, setProducts] = useState<Result | null>(null);
  const [customers, setCustomers] = useState<Result | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const productRows = sheets?.["Ürünler"] ?? [];
  const customerRows = sheets?.["Müşteriler"] ?? [];
  const containerRows = sheets?.["Müşteri Kapları"] ?? [];

  async function check(f: File) {
    setFile(f); setError(null); setProducts(null); setCustomers(null); setBusy(true);
    try {
      const wb = await readWorkbook(f);
      setSheets(wb);
      const sb = supabaseBrowser();
      if ((wb["Ürünler"] ?? []).length) {
        const { data, error } = await sb.rpc("import_products", { p_business: ctx.businessId, p_rows: wb["Ürünler"], p_dry_run: true });
        if (error) throw error;
        setProducts(data as Result);
      }
      if ((wb["Müşteriler"] ?? []).length || (wb["Müşteri Kapları"] ?? []).length) {
        const { data, error } = await sb.rpc("import_customers", {
          p_business: ctx.businessId, p_customers: wb["Müşteriler"] ?? [], p_containers: wb["Müşteri Kapları"] ?? [], p_dry_run: true,
        });
        if (error) throw error;
        setCustomers(data as Result);
      }
      if (!(wb["Ürünler"] ?? []).length && !(wb["Müşteriler"] ?? []).length) setError("Dosyada 'Ürünler' veya 'Müşteriler' sayfasında veri bulunamadı. Şablonu kullandığınızdan emin olun.");
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function apply() {
    setBusy(true); setError(null);
    const sb = supabaseBrowser();
    try {
      if (productRows.length && products?.ok) {
        const { data, error } = await sb.rpc("import_products", { p_business: ctx.businessId, p_rows: productRows, p_dry_run: false });
        if (error) throw error;
        setProducts(data as Result);
      }
      if ((customerRows.length || containerRows.length) && customers?.ok) {
        const { data, error } = await sb.rpc("import_customers", { p_business: ctx.businessId, p_customers: customerRows, p_containers: containerRows, p_dry_run: false });
        if (error) throw error;
        setCustomers(data as Result);
      }
      toast("Aktarım tamamlandı", "ok");
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const canApply = !!sheets && (products?.ok ?? true) && (customers?.ok ?? true) && !(products?.applied || customers?.applied) && (!!products || !!customers);

  return (
    <div className="space-y-4">
      <Card className="space-y-3">
        <p className="text-sm">1. Şablonu indirip doldurun. Başlıkları değiştirmeyin; açıklamalar şablonun ilk sayfasında.</p>
        <div className="flex flex-wrap gap-2">
          <a href="/templates/urun_ice_aktarma_sablonu.xlsx" download className="inline-flex h-11 items-center gap-2 rounded-xl border border-border px-4"><Download className="h-4 w-4" /> Excel şablonu</a>
          <a href="/templates/urun_ice_aktarma_sablonu.csv" download className="inline-flex h-11 items-center gap-2 rounded-xl border border-border px-4"><Download className="h-4 w-4" /> CSV şablonu</a>
        </div>
        <p className="text-sm">2. Doldurduğunuz dosyayı seçin. Önce kontrol edilir, siz onaylamadan hiçbir şey kaydedilmez.</p>
        <label className="flex cursor-pointer items-center justify-center gap-2 rounded-2xl border-2 border-dashed border-border p-6 text-muted hover:border-brand">
          <FileSpreadsheet className="h-6 w-6" />
          {file ? file.name : "Dosya seç (.xlsx veya .csv)"}
          <input type="file" accept=".xlsx,.csv" className="hidden" onChange={(e) => e.target.files?.[0] && check(e.target.files[0])} />
        </label>
      </Card>

      {busy ? <Alert tone="brand">İşleniyor…</Alert> : null}
      {error ? <Alert>{error}</Alert> : null}

      {products ? <ResultCard title="Ürünler" r={products} labels={{ rows: "Satır", new: "Yeni", updated: "Güncellenecek", new_brands: "Yeni marka", new_categories: "Yeni kategori" }} /> : null}
      {customers ? <ResultCard title="Müşteriler" r={customers} labels={{ rows: "Satır", new: "Yeni", updated: "Güncellenecek", containers: "Kap satırı" }} /> : null}

      {canApply ? (
        <Button size="lg" variant="ok" className="w-full" loading={busy} onClick={apply}>Onayla ve kaydet</Button>
      ) : null}
    </div>
  );
}

function ResultCard({ title, r, labels }: { title: string; r: Result; labels: Record<string, string> }) {
  return (
    <Card className="space-y-3">
      <div className="flex items-center justify-between">
        <h2 className="font-semibold">{title}</h2>
        {r.applied ? <span className="text-sm font-medium text-ok">Kaydedildi</span> : r.ok ? <span className="text-sm text-ok">Hata yok</span> : <span className="text-sm text-danger">{r.errors.length} hata</span>}
      </div>
      <div className="grid grid-cols-2 gap-2 md:grid-cols-5">
        {Object.entries(labels).map(([k, l]) => (r.summary?.[k] !== undefined ? <Stat key={k} label={l} value={r.summary[k]} /> : null))}
      </div>
      {r.errors.length ? <IssueList tone="danger" items={r.errors} /> : null}
      {r.warnings.length ? <IssueList tone="warn" items={r.warnings} /> : null}
    </Card>
  );
}

function IssueList({ items, tone }: { items: Issue[]; tone: "danger" | "warn" }) {
  return (
    <div className={tone === "danger" ? "rounded-xl bg-danger-soft p-3" : "rounded-xl bg-warn-soft p-3"}>
      <div className="mb-1 text-sm font-semibold">{tone === "danger" ? "Düzeltilmesi gerekenler" : "Uyarılar"}</div>
      <ul className="max-h-72 space-y-1 overflow-y-auto text-sm">
        {items.map((i, k) => (
          <li key={k}>{i.sheet ? `${i.sheet} ` : ""}Satır {i.row} · <b>{i.field}</b>: {i.message}</li>
        ))}
      </ul>
    </div>
  );
}
