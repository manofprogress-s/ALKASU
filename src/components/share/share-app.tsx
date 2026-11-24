"use client";
import { useState } from "react";
import { Camera, Copy, MessageCircle, MessageSquareText, Share2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { useToast } from "@/components/ui/toast";
import { SHARE_PATH, shareText, smsUrl, whatsappUrl } from "@/lib/share";

const row = "flex w-full items-center gap-3 rounded-xl border border-border bg-surface px-4 py-3 text-left font-medium hover:border-brand";

/** Ana sayfa sağ üst: uygulamayı WhatsApp, Instagram veya mesajla paylaş (M-30). Bağlantı herkese açık sipariş/kayıt sayfasıdır. */
export function ShareApp() {
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [url, setUrl] = useState("");
  const text = shareText(url);

  function start() {
    setUrl(`${window.location.origin}${SHARE_PATH}`);
    setOpen(true);
  }
  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      toast("Mesaj ve bağlantı kopyalandı", "ok");
      return true;
    } catch {
      toast("Kopyalanamadı; bağlantı: " + url, "danger");
      return false;
    }
  }
  // Instagram metinli paylaşım bağlantısı sunmaz: telefonun paylaşım menüsü (Instagram dahil) açılır; yoksa kopyalanıp Instagram açılır
  async function instagram() {
    if (typeof navigator.share === "function") {
      try {
        await navigator.share({ title: "ALKASU", text, url });
        return;
      } catch {
        return; // kullanıcı vazgeçti
      }
    }
    if (await copy()) window.open("https://www.instagram.com/direct/inbox/", "_blank", "noopener");
  }

  return (
    <>
      <Button variant="secondary" size="sm" onClick={start} aria-label="Uygulamayı paylaş">
        <Share2 className="h-4 w-4" /> Paylaş
      </Button>
      {open ? (
        <Dialog open onClose={() => setOpen(false)} title="Uygulamayı paylaş">
          <div className="space-y-2">
            <p className="text-sm text-muted">Müşteri bağlantıdan internetten sipariş verip hesabını açar.</p>
            <a className={row} href={whatsappUrl(text)} target="_blank" rel="noopener noreferrer" onClick={() => setOpen(false)}>
              <MessageCircle className="h-5 w-5 text-ok" /> WhatsApp
            </a>
            <button type="button" className={row} onClick={() => void instagram()}>
              <Camera className="h-5 w-5 text-brand" /> Instagram
            </button>
            <a className={row} href={smsUrl(text)} onClick={() => setOpen(false)}>
              <MessageSquareText className="h-5 w-5 text-brand" /> Mesaj (SMS)
            </a>
            <button type="button" className={row} onClick={() => void copy()}>
              <Copy className="h-5 w-5 text-muted" /> Bağlantıyı kopyala
            </button>
            <p className="break-all pt-1 text-xs text-muted">{url}</p>
          </div>
        </Dialog>
      ) : null}
    </>
  );
}
