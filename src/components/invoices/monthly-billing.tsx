"use client";
import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ChevronLeft, ChevronRight, FileStack } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { formatDate, formatNumber, formatTRY } from "@/lib/format";
import { addMonths, monthLabel } from "@/lib/profit";
import { TAX_KIND_LABEL, type InvoicePreview } from "@/lib/invoice";
import { cn } from "@/lib/cn";
import { InvoiceView } from "./invoice-view";
import { InvoiceSales } from "./invoice-sales";

export interface MonthlySale { id: string; no: number; sold_at: string; order_no: number | null; qty: number; total: number; over: boolean }
export interface MonthlyCustomer {
  customer_id: string; code: string; name: string; legal_title: string | null; channel: string; tax_kind: "vkn" | "tckn" | null;
  count: number; total: number; sales: MonthlySale[];
}
export interface MonthlyData { month: string; split_qty: number | null; customers: MonthlyCustomer[]; pending_months: string[]; aylik_customers: number }

/** Aylık toplu fatura (F-32): müşteri bazında ayın faturalanmamış teslimatları → kontrol ekranı → taslak. Hiçbir şey gönderilmez. */
export function MonthlyBilling({ data, month, thisMonth }: { data: MonthlyData; month: string; thisMonth: string }) {
  const href = (m: string) => `/faturalar?d=aylik&ay=${m}`;
  const nav = "inline-flex h-9 w-9 items-center justify-center rounded-xl border border-border bg-surface";
  const total = data.customers.reduce((s, c) => s + Number(c.total), 0);
  const others = data.pending_months.map((m) => m.slice(0, 7)).filter((m) => m !== month);
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Link href={href(addMonths(month, -1))} className={nav} aria-label="Önceki ay"><ChevronLeft className="h-4 w-4" /></Link>
        <span className="min-w-28 text-center font-semibold">{monthLabel(month)}</span>
        {month < thisMonth ? <Link href={href(addMonths(month, 1))} className={nav} aria-label="Sonraki ay"><ChevronRight className="h-4 w-4" /></Link> : null}
        {others.length ? (
          <span className="flex flex-wrap items-center gap-1 text-sm">
            <span className="text-muted">Bekleyen diğer aylar:</span>
            {others.map((m) => <Link key={m} href={href(m)} className="rounded-full bg-warn-soft px-2 py-0.5 text-warn">{monthLabel(m, true)}</Link>)}
          </span>
        ) : null}
      </div>
      <SplitSetting value={data.split_qty} />
      {data.aylik_customers === 0 ? (
        <Alert tone="neutral">Henüz “Aylık toplu” faturalanan müşteri yok. Müşteri kartında <b>Fatura bilgileri → Fatura yöntemi</b>’nden seçebilirsiniz.</Alert>
      ) : null}
      {data.customers.length ? (
        <p className="text-sm text-muted">{data.customers.length} müşteri · {formatTRY(total)} · fatura bekleyen teslimatlar</p>
      ) : data.aylik_customers > 0 ? (
        <div className="rounded-2xl border border-dashed border-border p-8 text-center text-muted">{monthLabel(month)} için faturalanacak aylık teslimat yok</div>
      ) : null}
      {data.customers.map((c) => <CustomerBatch key={c.customer_id} c={c} split={data.split_qty} />)}
    </div>
  );
}

function SplitSetting({ value }: { value: number | null }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [v, setV] = useState(value ? String(value) : "");
  const [busy, setBusy] = useState(false);
  async function save() {
    const n = v.trim() ? Number.parseInt(v, 10) : null;
    if (n !== null && (!Number.isFinite(n) || n < 1)) return toast("Eşik 1 veya daha büyük bir sayı olmalı", "danger");
    setBusy(true);
    const { error } = await supabaseBrowser().rpc("set_invoice_split_qty", { p_business: ctx.businessId, p_qty: n });
    setBusy(false);
    if (error) return toast(errorMessage(error), "danger");
    toast(n ? `Eşik ${n} birim` : "Eşik kapatıldı", "ok");
    router.refresh();
  }
  return (
    <Card className="flex flex-wrap items-center gap-2 py-2 text-sm">
      <span className="font-medium">Ayrı fatura eşiği</span>
      <Input className="h-9 w-24" inputMode="numeric" value={v} onChange={(e) => setV(e.target.value.replace(/\D/g, ""))} placeholder="kapalı" aria-label="Eşik (birim)" />
      <span className="text-muted">birim ve üzeri teslimat aylık faturaya otomatik eklenmez, ayrı faturalanır. Boş = kapalı.</span>
      <Button size="sm" variant="secondary" loading={busy} disabled={(value ? String(value) : "") === v} onClick={() => void save()}>Kaydet</Button>
    </Card>
  );
}

function CustomerBatch({ c, split }: { c: MonthlyCustomer; split: number | null }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [sel, setSel] = useState<Set<string>>(() => new Set(c.sales.filter((s) => !s.over).map((s) => s.id)));
  const [preview, setPreview] = useState<InvoicePreview | null>(null);
  const [busy, setBusy] = useState<"preview" | "create" | null>(null);
  const chosen = c.sales.filter((s) => sel.has(s.id));
  const sum = chosen.reduce((s, x) => s + Number(x.total), 0);
  const toggle = (id: string) => setSel((x) => { const n = new Set(x); if (n.has(id)) n.delete(id); else n.add(id); return n; });

  async function openPreview() {
    setBusy("preview");
    const { data, error } = await supabaseBrowser().rpc("invoice_preview_multi", { p_business: ctx.businessId, p_sales: chosen.map((s) => s.id) });
    setBusy(null);
    if (error) return toast(errorMessage(error), "danger");
    setPreview(data as InvoicePreview);
  }
  async function create() {
    setBusy("create");
    const { data, error } = await supabaseBrowser().rpc("create_invoice", { p_business: ctx.businessId, p_sales: chosen.map((s) => s.id), p_kind: "aylik", p_note: null });
    setBusy(null);
    if (error) return toast(errorMessage(error), "danger");
    toast(`Aylık fatura taslağı oluşturuldu (${chosen.length} teslimat)`, "ok");
    router.push(`/faturalar/${data as string}`);
  }
  const errors = preview?.issues.filter((i) => i.level === "error").length ?? 0;

  return (
    <Card className="space-y-2">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <Link href={`/musteriler/${c.customer_id}`} className="font-semibold hover:underline">{c.legal_title ?? c.name}</Link>
          <div className="flex flex-wrap items-center gap-1.5 text-xs text-muted">
            <span>{c.code}</span>
            {c.tax_kind ? <Badge tone="ok">{TAX_KIND_LABEL[c.tax_kind]}</Badge> : <Badge tone={c.channel === "kurumsal" ? "danger" : "warn"}>Vergi no yok</Badge>}
            <span>{c.count} teslimat · {formatTRY(c.total)}</span>
          </div>
        </div>
        <Button loading={busy === "preview"} disabled={!chosen.length} onClick={() => void openPreview()}>
          <FileStack className="h-4 w-4" /> Kontrol et ({chosen.length})
        </Button>
      </div>
      <ul className="divide-y divide-border rounded-xl border border-border text-sm">
        {c.sales.map((s) => (
          <li key={s.id} className={cn("flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-1.5", s.over && "bg-warn-soft/50")}>
            <label className="flex min-w-0 flex-1 items-center gap-2">
              <input type="checkbox" className="h-4 w-4 accent-[var(--brand)]" checked={sel.has(s.id)} onChange={() => toggle(s.id)} />
              <span className="font-medium">#{s.no}</span>
              <span className="text-muted">{s.order_no ? `Sipariş #${s.order_no}` : "Dükkân"} · {formatDate(s.sold_at)}</span>
            </label>
            <span className="num">{formatNumber(s.qty)} birim · {formatTRY(s.total)}</span>
            {s.over ? (
              <span className="flex items-center gap-2">
                <Badge tone="warn">Eşik üstü ({split})</Badge>
                <Link href={`/satislar/${s.id}`} className="text-xs font-medium text-brand">Ayrı fatura →</Link>
              </span>
            ) : null}
          </li>
        ))}
      </ul>
      {chosen.length ? <p className="text-right text-sm text-muted">Seçilen: {chosen.length} teslimat · {formatTRY(sum)} (depozito hariç)</p> : null}

      <Dialog open={!!preview} onClose={() => setPreview(null)} wide title={`Aylık fatura kontrolü · ${c.legal_title ?? c.name}`}
        footer={
          <div className="flex w-full flex-wrap items-center justify-end gap-2">
            {errors ? <span className="mr-auto text-sm text-danger">{errors} hata var; taslak kaydedilebilir, gönderime hazırlamadan önce düzeltin.</span> : null}
            <Button variant="ghost" onClick={() => setPreview(null)}>Vazgeç</Button>
            <Button loading={busy === "create"} onClick={() => void create()}>Aylık fatura taslağı oluştur</Button>
          </div>
        }>
        {preview ? (
          <div className="space-y-3">
            <p className="text-sm text-muted">
              {preview.period_start ? `${formatDate(preview.period_start)} – ${formatDate(preview.period_end)} · ` : ""}
              Yalnızca teslim edilen (iadeler düşülmüş) miktarlar faturalanır. Taslak Logo’ya gönderilmez.
            </p>
            <InvoiceView customer={preview.customer} lines={preview.lines} totals={preview.totals} issues={preview.issues} docTypeHint={preview.doc_type_hint} />
            <InvoiceSales sales={preview.sales ?? []} />
          </div>
        ) : null}
      </Dialog>
    </Card>
  );
}
