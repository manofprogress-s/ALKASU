"use client";
import { useRef, useState } from "react";
import { ImagePlus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
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
  return new Promise((res, rej) => canvas.toBlob((b) => (b ? res(b) : rej(new Error("Görsel işlenemedi"))), "image/webp", 0.85));
}

/** Ürün fotoğrafı (yalnızca yönetici): müşteri sipariş ekranında gösterilir (W-09) */
export function ProductImage({ productId, path }: { productId: string; path: string | null }) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const input = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const url = productImageUrl(path);

  async function upload(file: File) {
    setError(null);
    if (!file.type.startsWith("image/")) return setError("Lütfen bir fotoğraf seçin.");
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
    } catch (e) {
      setError(e instanceof Error ? e.message : "Fotoğraf yüklenemedi");
    } finally {
      setUploading(false);
      if (input.current) input.current.value = "";
    }
  }

  async function remove() {
    const ok = await call("set_product_image", { p_product: productId, p_path: null }, { success: "Fotoğraf kaldırıldı" });
    if (ok && path) await supabaseBrowser().storage.from(PRODUCT_IMAGE_BUCKET).remove([path]);
  }

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
          <input ref={input} type="file" accept="image/*" className="hidden" onChange={(e) => { const f = e.target.files?.[0]; if (f) void upload(f); }} />
          <Button variant="secondary" loading={uploading} onClick={() => input.current?.click()}>
            <ImagePlus className="h-4 w-4" /> {url ? "Değiştir" : "Fotoğraf yükle"}
          </Button>
          {url ? <Button variant="ghost" loading={busy} onClick={() => void remove()}><Trash2 className="h-4 w-4" /> Kaldır</Button> : null}
        </div>
      </div>
      {error ? <Alert>{error}</Alert> : null}
    </Card>
  );
}
