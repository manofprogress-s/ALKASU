"use client";
import { Button } from "@/components/ui/button";
import { useRpc } from "@/lib/use-action";

/** Ürün listesinde aktif/pasif düğmesi (F-41): yönetici veya özel fiyat yetkilisi. */
export function ProductActiveToggle({ productId, active }: { productId: string; active: boolean }) {
  const { call, busy } = useRpc();
  return (
    <Button size="sm" variant={active ? "ghost" : "ok"} loading={busy}
      title={active ? "Pasife al: satış, sipariş ve fiyat ekranlarından kalkar" : "Aktif yap"}
      onClick={() => call("set_product_active", { p_product: productId, p_active: !active }, { success: active ? "Ürün pasife alındı" : "Ürün aktif" })}>
      {active ? "Pasife al" : "Aktif yap"}
    </Button>
  );
}
