"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { CheckCircle2, FileText, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Textarea } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { taxIdKind, TAX_KIND_LABEL } from "@/lib/invoice";

export interface BillingValues {
  legal_title: string | null; tax_no: string | null; tax_office: string | null; email: string | null;
  city: string | null; district: string | null; address: string | null; channel: string;
  logo_code?: string | null;
}

/** Müşteri kartında fatura bilgileri (F-20). Personel girer; doğrulama anında gösterilir. */
export function BillingCard({ customerId, v, canEdit, highlight }: { customerId: string; v: BillingValues; canEdit: boolean; highlight?: boolean }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [open, setOpen] = useState(!!highlight && canEdit);
  const [f, setF] = useState(() => ({
    legal_title: v.legal_title ?? "", tax_no: v.tax_no ?? "", tax_office: v.tax_office ?? "", email: v.email ?? "",
    city: v.city ?? "", district: v.district ?? "", address: v.address ?? "",
  }));
  const [saving, setSaving] = useState(false);
  const kind = taxIdKind(f.tax_no);
  const savedKind = taxIdKind(v.tax_no);
  const digits = f.tax_no.replace(/\D/g, "");
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));

  const missing: string[] = [];
  if (!v.tax_no) missing.push("VKN/TCKN");
  if (savedKind === "vkn" && !v.tax_office) missing.push("vergi dairesi");
  if (!v.address) missing.push("adres");
  if (!v.city || !v.district) missing.push("il/ilçe");
  if (!v.email) missing.push("e-posta");

  async function unlink() {
    const { error } = await supabaseBrowser().rpc("logo_firm_unlink", { p_business: ctx.businessId, p_customer: customerId });
    if (error) return toast(errorMessage(error), "danger");
    toast("İşbaşı bağlantısı kaldırıldı", "ok");
    router.refresh();
  }

  async function save() {
    if (digits && !kind) return toast("VKN/TCKN geçersiz", "danger");
    setSaving(true);
    const { error } = await supabaseBrowser().rpc("set_customer_billing", { p_business: ctx.businessId, p_customer: customerId, p: f });
    setSaving(false);
    if (error) return toast(errorMessage(error), "danger");
    toast("Fatura bilgileri kaydedildi", "ok");
    setOpen(false);
    router.refresh();
  }

  return (
    <Card id="fatura-bilgileri" className={`scroll-mt-16 space-y-2 ${highlight ? "ring-2 ring-warn/50" : ""}`}>
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <h2 className="flex items-center gap-1.5 font-semibold"><FileText className="h-4 w-4 text-brand" /> Fatura bilgileri</h2>
          {v.tax_no ? (
            <div className="text-sm">
              <span className="font-medium">{v.legal_title ?? "—"}</span>
              <span className="block text-muted">
                {savedKind ? TAX_KIND_LABEL[savedKind] : "Geçersiz no"}: {v.tax_no}{v.tax_office ? ` · ${v.tax_office} VD` : ""}
              </span>
              <span className="block text-muted">{[v.address, v.district, v.city].filter(Boolean).join(", ") || "Adres yok"}{v.email ? ` · ${v.email}` : ""}</span>
            </div>
          ) : <p className="text-sm text-muted">Henüz girilmedi.</p>}
        </div>
        {canEdit ? <Button size="sm" variant={missing.length ? "primary" : "secondary"} onClick={() => setOpen(true)}>{v.tax_no ? "Düzenle" : "Gir"}</Button> : null}
      </div>
      {missing.length ? (
        <p className="flex items-center gap-1.5 text-sm text-warn"><TriangleAlert className="h-4 w-4 shrink-0" /> Fatura için eksik: {missing.join(", ")}</p>
      ) : <p className="flex items-center gap-1.5 text-sm text-ok"><CheckCircle2 className="h-4 w-4" /> Fatura için bilgiler tamam</p>}
      {v.logo_code ? (
        <p className="flex flex-wrap items-center gap-x-2 text-xs text-muted">
          <span>İşbaşı cari kodu: <span className="num text-text">{v.logo_code.replace(/^0+/, "")}</span></span>
          {ctx.role === "yonetici" ? <button type="button" className="text-danger underline-offset-2 hover:underline" onClick={() => void unlink()}>bağlantıyı kaldır</button> : null}
        </p>
      ) : ctx.role === "yonetici" ? <p className="text-xs text-muted">İşbaşı’ndaki cariyle henüz eşleştirilmedi.</p> : null}

      <Dialog open={open} onClose={() => setOpen(false)} title="Fatura bilgileri"
        footer={<Button size="lg" className="w-full" loading={saving} onClick={() => void save()}>Kaydet</Button>}>
        <div className="space-y-3">
          <Field label="VKN / TCKN" hint="Şirket: 10 haneli vergi no · Şahıs: 11 haneli T.C. kimlik no">
            <Input inputMode="numeric" value={f.tax_no} onChange={set("tax_no")} placeholder="Örn. 1234567890" />
            {digits ? (
              <span className={`mt-1 block text-xs ${kind ? "text-ok" : "text-danger"}`}>
                {kind ? `✓ Geçerli ${TAX_KIND_LABEL[kind]}` : digits.length === 10 || digits.length === 11 ? "Doğrulama hanesi tutmuyor — numarayı kontrol edin" : `${digits.length} hane girildi (10 veya 11 olmalı)`}
              </span>
            ) : null}
          </Field>
          <Field label="Resmî unvan" hint={kind === "tckn" ? "Şahıs ise ad soyad" : "Vergi levhasındaki tam unvan"}>
            <Input value={f.legal_title} onChange={set("legal_title")} placeholder="Örn. Örnek Lojistik Ltd. Şti." />
          </Field>
          {kind !== "tckn" ? <Field label="Vergi dairesi"><Input value={f.tax_office} onChange={set("tax_office")} placeholder="Örn. Gebze" /></Field> : null}
          <div className="grid grid-cols-2 gap-2">
            <Field label="İl"><Input value={f.city} onChange={set("city")} placeholder="Kocaeli" /></Field>
            <Field label="İlçe"><Input value={f.district} onChange={set("district")} placeholder="Kartepe" /></Field>
          </div>
          <Field label="Fatura adresi"><Textarea value={f.address} onChange={set("address")} /></Field>
          <Field label="E-posta" hint="e-Arşiv fatura bu adrese gönderilir">
            <Input type="email" inputMode="email" value={f.email} onChange={set("email")} placeholder="muhasebe@firma.com" />
          </Field>
        </div>
      </Dialog>
    </Card>
  );
}
