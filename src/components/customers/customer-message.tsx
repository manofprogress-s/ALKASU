"use client";
import { useState, type MouseEvent } from "react";
import { MessageCircle, MessageSquareText, Send, TriangleAlert } from "lucide-react";
import { Alert } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { formatDate } from "@/lib/format";
import { mobileIntl, smsLink, TEMPLATES, whatsappLink, type MessageChannel, type MessageTemplate } from "@/lib/messages";

export interface MessageTarget {
  id: string;
  name: string;
  phones: (string | null)[];
  channel: string;               // perakende | kurumsal | bayi
  consent?: boolean | null;      // kampanya izni (bilinmiyorsa uyarı gösterilmez)
  lastMessage?: { template: string; at: string } | null;
}

/**
 * Müşteri listesinde küçük "Mesaj" düğmesi (M-27): taslak seçilir, WhatsApp veya SMS uygulaması hazır metinle açılır.
 * Mesajı sistem göndermez; gönderim (açılış) kaydı tutulur.
 */
export function CustomerMessage({ target, compact }: { target: MessageTarget; compact?: boolean }) {
  const ctx = useAppContext();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [tpl, setTpl] = useState<MessageTemplate>("tanitim");
  const [last, setLast] = useState(target.lastMessage ?? null);
  const mobiles = [...new Set(target.phones.map(mobileIntl).filter((x): x is string => !!x))];
  const [phone, setPhone] = useState(mobiles[0] ?? "");
  const text = TEMPLATES[tpl].text;

  // Bağlantı açılırken kayıt tutulur; kayıt hatası (ör. müşteri kampanya istemiyor) uygulamayı açmayı engeller
  async function go(e: MouseEvent<HTMLAnchorElement>, channel: MessageChannel) {
    e.preventDefault();
    const href = e.currentTarget.href;
    const w = channel === "whatsapp" ? window.open("about:blank", "_blank") : null;
    const { error } = await supabaseBrowser().rpc("log_customer_message", { p_business: ctx.businessId, p_customer: target.id, p_template: tpl, p_channel: channel });
    if (error) {
      w?.close();
      return toast(errorMessage(error), "danger");
    }
    setLast({ template: tpl, at: new Date().toISOString() });
    if (w) w.location.href = href; else window.location.href = href;
    setOpen(false);
  }

  return (
    <>
      <button type="button" onClick={() => setOpen(true)} disabled={!mobiles.length}
        title={mobiles.length ? "WhatsApp / SMS mesajı" : "Cep telefonu yok"} aria-label={`${target.name}: mesaj gönder`}
        className={`inline-flex items-center gap-1 rounded-lg border border-border px-2 text-xs font-medium hover:border-brand hover:text-brand disabled:opacity-40 ${compact ? "h-8" : "h-9"}`}>
        <MessageCircle className="h-4 w-4" />
        {last ? <span className="text-muted">{formatDate(last.at).slice(0, 5)}</span> : <span>Mesaj</span>}
      </button>
      <Dialog open={open} onClose={() => setOpen(false)} title={`${target.name} · mesaj`}>
        <div className="space-y-3 text-sm">
          <div className="grid gap-2">
            {(Object.keys(TEMPLATES) as MessageTemplate[]).map((k) => (
              <label key={k} className={`flex cursor-pointer gap-2 rounded-xl border p-2.5 ${tpl === k ? "border-brand bg-brand-soft" : "border-border"}`}>
                <input type="radio" name={`tpl-${target.id}`} checked={tpl === k} onChange={() => setTpl(k)} className="mt-0.5" />
                <span><span className="block font-medium">{TEMPLATES[k].label}</span><span className="block text-xs text-muted">{TEMPLATES[k].hint}</span></span>
              </label>
            ))}
          </div>
          <pre className="whitespace-pre-wrap rounded-xl border border-border bg-surface-2 p-3 font-sans text-xs">{text}</pre>
          {mobiles.length > 1 ? (
            <select value={phone} onChange={(e) => setPhone(e.target.value)} className="h-10 w-full rounded-xl border border-border bg-surface px-3">
              {mobiles.map((m) => <option key={m} value={m}>+{m}</option>)}
            </select>
          ) : <p className="text-xs text-muted">Numara: +{phone}</p>}
          {target.channel === "perakende" && target.consent === false ? (
            <Alert tone="warn">
              <span className="flex items-start gap-1.5"><TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" />
                Bu ev müşterisinin kayıtlı kampanya izni yok. Tanıtım/hatırlatma mesajı ticari ileti sayılabilir; daha önce sizden alışveriş yapmış ve itiraz etmemiş müşterilere gönderin.</span>
            </Alert>
          ) : null}
          {last ? <p className="text-xs text-muted">Son mesaj: {formatDate(last.at)} · {TEMPLATES[last.template as MessageTemplate]?.label ?? last.template}</p> : null}
          <div className="grid grid-cols-2 gap-2">
            <a href={whatsappLink(phone, text)} onClick={(e) => void go(e, "whatsapp")}
              className="inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-brand font-medium text-white hover:bg-brand/90">
              <Send className="h-4 w-4" /> WhatsApp’ta aç
            </a>
            <a href={smsLink(phone, text)} onClick={(e) => void go(e, "sms")}
              className="inline-flex h-11 items-center justify-center gap-2 rounded-xl border border-border font-medium hover:border-brand">
              <MessageSquareText className="h-4 w-4" /> SMS’te aç
            </a>
          </div>
          <p className="text-xs text-muted">Mesaj telefonunuzdaki uygulamada hazır açılır; göndermek için oradan “Gönder”e basın.</p>
        </div>
      </Dialog>
    </>
  );
}
