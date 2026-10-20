"use client";
import { useRef, useState } from "react";
import { Image as ImageIcon, ImagePlus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { useRpc } from "@/lib/use-action";
import { PRODUCT_IMAGE_BUCKET, productImageUrl } from "@/lib/shop";

/** Fotoğrafı tarayıcıda en fazla 600 px'e küçültüp webp'ye çevirir (hızlı açılış, küçük depolama) */
async function shrink(file: File): Promise<Blob> {
  const bmp = await createImageBitmap(file);
  const scale = Math.min(1, 600 / Math.max(bmp.width, bmp.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bmp.width * scale);
  canvas.height = Math.round(bmp.height * scale);
  canvas.getContext("2d")!.drawImage(bmp, 0, 0, canvas.width, canvas.height);
  bmp.close();
  return new Promise((res, rej) => canvas.toBlob((b) => (b ? res(b) : rej(new Error("Görsel işlenemedi"))), "image/webp", 0.85));
}

/** Yükleme/kaldırma mantığı: ürün sayfası ve ürün listesindeki hızlı düğme aynı akışı kullanır (W-09) */
function useProductImage(productId: string, path: string | null) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const input = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  /** Başarılıysa null, değilse hata mesajı döner ("" = mesaj zaten gösterildi) */
  async function upload(file: File): Promise<string | null> {
    setError(null);
    if (!file.type.startsWith("image/")) {
      setError("Lütfen bir fotoğraf seçin.");
      return "Lütfen bir fotoğraf seçin.";
    }
    setUploading(true);
    try {
      const blob = await shrink(file);
      const newPath = `${ctx.businessId}/${productId}-${Date.now()}.webp`;
      const storage = supabaseBrowser().storage.from(PRODUCT_IMAGE_BUCKET);
      const up = await storage.upload(newPath, blob, { contentType: "image/webp", cacheControl: "31536000" });
      if (up.error) throw up.error;
      const ok = await call("set_product_image", { p_product: productId, p_path: newPath }, { success: "Fotoğraf kaydedildi" });
      if (!ok) await storage.remove([newPath]);
      else if (path) await storage.remove([path]); // eski dosya
      return ok ? null : ""; // "" = hata zaten bildirim olarak gösterildi
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Fotoğraf yüklenemedi";
      setError(msg);
      return msg;
    } finally {
      setUploading(false);
      if (input.current) input.current.value = "";
    }
  }

  async function remove(): Promise<boolean> {
    const ok = await call("set_product_image", { p_product: productId, p_path: null }, { success: "Fotoğraf kaldırıldı" });
    if (ok && path) await supabaseBrowser().storage.from(PRODUCT_IMAGE_BUCKET).remove([path]);
    return !!ok;
  }

  const fileInput = (onPicked: (f: File) => void) => (
    <input ref={input} type="file" accept="image/*" className="hidden" onChange={(e) => { const f = e.target.files?.[0]; if (f) onPicked(f); }} />
  );
  return { upload, remove, uploading, busy, error, input, fileInput };
}

/** Ürün fotoğrafı (yalnızca yönetici): müşteri sipariş ekranında gösterilir (W-09) */
export function ProductImage({ productId, path }: { productId: string; path: string | null }) {
  const img = useProductImage(productId, path);
  const url = productImageUrl(path);

  return (
    <Card className="space-y-3">
      <div>
        <h2 className="font-semibold">Fotoğraf</h2>
        <p className="text-sm text-muted">Müşterinin sipariş ekranında görünür. Beyaz/açık zemin üzerinde, ürünün tamamı görünen dik bir fotoğraf en iyi sonucu verir.</p>
      </div>
      <div className="flex items-center gap-4">
        <div className="flex h-32 w-28 items-center justify-center rounded-xl border border-border bg-bg">
          {url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={url} alt="Ürün fotoğrafı" className="h-full w-full object-contain" />
          ) : <span className="px-2 text-center text-xs text-muted">Fotoğraf yok — çizim gösterilir</span>}
        </div>
        <div className="flex flex-col gap-2">
          {img.fileInput((f) => void img.upload(f))}
          <Button variant="secondary" loading={img.uploading} onClick={() => img.input.current?.click()}>
            <ImagePlus className="h-4 w-4" /> {url ? "Değiştir" : "Fotoğraf yükle"}
          </Button>
          {url ? <Button variant="ghost" loading={img.busy} onClick={() => void img.remove()}><Trash2 className="h-4 w-4" /> Kaldır</Button> : null}
        </div>
      </div>
      {img.error ? <Alert>{img.error}</Alert> : null}
    </Card>
  );
}

/**
 * Ürün listesindeki küçük görsel düğmesi (W-11).
 * Görsel yoksa: tıklayınca doğrudan dosya seçilir. Varsa: önizleme penceresi (Değiştir / Kaldır).
 * Listede hiçbir fotoğraf indirilmez; önizleme yalnızca pencere açılınca yüklenir.
 */
export function ProductImageQuick({ productId, productName, path }: { productId: string; productName: string; path: string | null }) {
  const img = useProductImage(productId, path);
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const url = productImageUrl(path);

  async function picked(f: File) {
    const err = await img.upload(f);
    if (err === null) setOpen(false);
    else if (err && !open) toast(err, "danger"); // pencere kapalıyken hata bildirim olarak görünür
  }

  const pick = () => img.input.current?.click();
  return (
    <>
      {img.fileInput((f) => void picked(f))}
      {url ? (
        <button type="button" onClick={() => setOpen(true)} title="Görsel var — değiştir" aria-label={`${productName}: görseli değiştir`}
          className="inline-flex h-8 w-8 items-center justify-center rounded-lg text-brand hover:bg-surface-2 focus-visible:outline-2 focus-visible:outline-brand">
          <ImageIcon className="h-4 w-4" />
        </button>
      ) : (
        <button type="button" onClick={pick} disabled={img.uploading} title="Görsel ekle" aria-label={`${productName}: görsel ekle`}
          className="inline-flex h-8 w-8 items-center justify-center rounded-lg border border-dashed border-border text-muted hover:border-brand hover:text-brand disabled:opacity-60 focus-visible:outline-2 focus-visible:outline-brand">
          {img.uploading ? <span className="h-3.5 w-3.5 animate-spin rounded-full border-2 border-current border-t-transparent" /> : <ImagePlus className="h-4 w-4" />}
        </button>
      )}
      {url ? (
        <Dialog open={open} onClose={() => setOpen(false)} title={productName}
          footer={
            <div className="flex w-full flex-wrap justify-end gap-2">
              <Button variant="ghost" className="text-danger" loading={img.busy} onClick={() => void img.remove().then((ok) => ok && setOpen(false))}>
                <Trash2 className="h-4 w-4" /> Kaldır
              </Button>
              <Button loading={img.uploading} onClick={pick}><ImagePlus className="h-4 w-4" /> Değiştir</Button>
            </div>
          }>
          <div className="space-y-2">
            <div className="mx-auto flex h-56 w-48 items-center justify-center rounded-xl border border-border bg-bg">
              {open ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={url} alt={productName} className="h-full w-full object-contain" />
              ) : null}
            </div>
            {img.error ? <Alert>{img.error}</Alert> : null}
            <p className="text-center text-xs text-muted">Yeni fotoğraf otomatik küçültülür (en fazla 600 px).</p>
          </div>
        </Dialog>
      ) : null}
    </>
  );
}
