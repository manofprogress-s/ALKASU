"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { RefreshCw, Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import type { InvoiceStatus } from "@/lib/invoice";

/** Fatura kaydı eylemleri (F-23). "Logo'ya gönder" bağlantı kurulana kadar kapalı. */
export function InvoiceActions({ invoiceId, status, errors }: { invoiceId: string; status: InvoiceStatus; errors: number }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [reason, setReason] = useState("");

  async function act(action: string, note?: string) {
    setBusy(action);
    const { error } = await supabaseBrowser().rpc("invoice_action", { p_business: ctx.businessId, p_invoice: invoiceId, p_action: action, p_note: note ?? null });
    setBusy(null);
    if (error) return toast(errorMessage(error), "danger");
    toast(
      action === "hazirla" ? "Gönderime hazır" : action === "yenile" ? "Bilgiler güncellendi" : action === "taslaga" ? "Taslağa alındı" : "Fatura kaydı iptal edildi",
      "ok",
    );
    setCancelOpen(false);
    router.refresh();
  }

  if (status === "iptal" || status === "resmilesti" || status === "gonderildi" || status === "gonderiliyor") return null;
  return (
    <Card className="space-y-3">
      <div className="flex flex-wrap gap-2">
        {status === "taslak" ? (
          <>
            <Button variant="secondary" loading={busy === "yenile"} onClick={() => void act("yenile")}>
              <RefreshCw className="h-4 w-4" /> Müşteri ve satış bilgisini yenile
            </Button>
            <Button loading={busy === "hazirla"} disabled={errors > 0} onClick={() => void act("hazirla")}>Gönderime hazırla</Button>
          </>
        ) : null}
        {status === "hazir" ? (
          <>
            <Button variant="secondary" loading={busy === "taslaga"} onClick={() => void act("taslaga")}>Taslağa geri al</Button>
            <Button disabled title="Logo İşbaşı bağlantısı henüz kurulmadı">
              <Send className="h-4 w-4" /> Logo'ya gönder
            </Button>
          </>
        ) : null}
        <Button variant="ghost" className="text-danger" onClick={() => setCancelOpen(true)}>Kaydı iptal et</Button>
      </div>
      {status === "taslak" && errors > 0 ? <p className="text-sm text-muted">Gönderime hazırlamak için önce kırmızı eksikleri tamamlayın, sonra “yenile”ye basın.</p> : null}
      {status === "hazir" ? (
        <Alert tone="neutral">Logo İşbaşı bağlantısı kurulunca bu düğme açılacak. Gönderim yalnızca sizin onayınızla ve önce test ortamında yapılacak.</Alert>
      ) : null}
      <Dialog open={cancelOpen} onClose={() => setCancelOpen(false)} title="Fatura kaydını iptal et"
        footer={<Button variant="danger" className="w-full" loading={busy === "iptal"} disabled={reason.trim().length < 3} onClick={() => void act("iptal", reason)}>İptal et</Button>}>
        <div className="space-y-2">
          <p className="text-sm text-muted">Yalnızca ALKASU'daki kayıt iptal edilir; satış yeniden faturalanabilir. Logo'ya gönderilmiş bir şey yoktur.</p>
          <Field label="İptal nedeni"><Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Örn. yanlış müşteri seçilmiş" /></Field>
        </div>
      </Dialog>
    </Card>
  );
}
