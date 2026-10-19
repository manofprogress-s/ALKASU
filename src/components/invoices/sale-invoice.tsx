"use client";
import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { FileText } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { INVOICE_STATUS, type InvoicePreview, type InvoiceStatus } from "@/lib/invoice";
import { InvoiceView } from "./invoice-view";

/** Satış detayında fatura kartı (F-21): kayıt varsa durumu, yoksa "Faturayı hazırla" (önizleme → taslak) */
export function SaleInvoice({ saleId, saleActive, invoice }: {
  saleId: string; saleActive: boolean; invoice: { id: string; no: number; status: InvoiceStatus } | null;
}) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [preview, setPreview] = useState<InvoicePreview | null>(null);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);

  async function openPreview() {
    setLoading(true);
    const { data, error } = await supabaseBrowser().rpc("invoice_preview", { p_sale: saleId });
    setLoading(false);
    if (error) return toast(errorMessage(error), "danger");
    setPreview(data as InvoicePreview);
  }

  async function createDraft() {
    setSaving(true);
    const { data, error } = await supabaseBrowser().rpc("create_invoice_draft", { p_business: ctx.businessId, p_sale: saleId });
    setSaving(false);
    if (error) return toast(errorMessage(error), "danger");
    toast("Fatura taslağı oluşturuldu", "ok");
    router.push(`/faturalar/${data as string}`);
  }

  if (invoice) {
    const st = INVOICE_STATUS[invoice.status];
    return (
      <Card className="flex flex-wrap items-center justify-between gap-2">
        <span className="flex items-center gap-2">
          <FileText className="h-5 w-5 text-brand" />
          <span>
            <span className="block font-semibold">Fatura kaydı F-{invoice.no}</span>
            <span className="block text-xs text-muted">{st.hint}</span>
          </span>
        </span>
        <span className="flex items-center gap-2">
          <Badge tone={st.tone}>{st.label}</Badge>
          <Link href={`/faturalar/${invoice.id}`} className="inline-flex h-10 items-center rounded-xl border border-border px-3 text-sm font-medium">Aç</Link>
        </span>
      </Card>
    );
  }
  if (!saleActive) return null;
  const errors = preview?.issues.filter((i) => i.level === "error").length ?? 0;
  return (
    <>
      <Card className="flex flex-wrap items-center justify-between gap-2">
        <span className="flex items-center gap-2">
          <FileText className="h-5 w-5 text-muted" />
          <span>
            <span className="block font-semibold">Faturası yok</span>
            <span className="block text-xs text-muted">Önizleyip taslak oluşturun. Logo'ya henüz gönderilmez.</span>
          </span>
        </span>
        <Button loading={loading} onClick={() => void openPreview()}>Faturayı hazırla</Button>
      </Card>
      <Dialog open={!!preview} onClose={() => setPreview(null)} wide title={preview ? `Fatura önizlemesi · Satış #${preview.sale.no}` : ""}
        footer={
          <div className="flex w-full flex-wrap items-center justify-end gap-2">
            {errors ? <span className="mr-auto text-sm text-danger">{errors} eksik var; taslak kaydedilebilir, gönderime hazırlamadan önce düzeltin.</span> : null}
            <Button variant="ghost" onClick={() => setPreview(null)}>Vazgeç</Button>
            <Button loading={saving} onClick={() => void createDraft()}>Taslak olarak kaydet</Button>
          </div>
        }>
        {preview ? <InvoiceView customer={preview.customer} lines={preview.lines} totals={preview.totals} issues={preview.issues} docTypeHint={preview.doc_type_hint} /> : null}
      </Dialog>
    </>
  );
}
