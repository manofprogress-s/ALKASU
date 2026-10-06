import { redirect } from "next/navigation";
import Link from "next/link";
import { supabaseServer } from "@/lib/supabase/server";
import { sessionUser } from "@/lib/supabase/claims";
import { Alert, Card } from "@/components/ui/card";
import { PublicOrderForm, type PublicItem } from "@/components/public/public-order-form";

export const metadata = { title: "Sipariş ver" };
export const dynamic = "force-dynamic";

/** Herkese açık sipariş + kayıt (D-051). Giriş yapmış kullanıcı kendi sipariş ekranına gider. */
export default async function PublicOrderPage() {
  const supabase = await supabaseServer();
  if (await sessionUser(supabase)) redirect("/siparisler/yeni");
  const { data, error } = await supabase.rpc("public_catalog");
  const items = ((data ?? []) as { product_id: string; product_name: string; unit_id: string; unit_name: string; factor: number; price: number; has_deposit: boolean }[]).map(
    (r): PublicItem => ({ productId: r.product_id, productName: r.product_name, unitId: r.unit_id, unitName: r.unit_name, factor: r.factor, price: Number(r.price), hasDeposit: r.has_deposit }),
  );
  return (
    <main className="mx-auto max-w-2xl space-y-4 p-4 pb-16">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-2xl font-bold tracking-tight text-brand">ALKASU</div>
          <div className="text-sm text-muted">Alay Ticaret · Su ve damacana siparişi</div>
        </div>
        <Link href="/giris?tip=musteri" className="text-sm text-brand">Kayıtlıyım, giriş yap</Link>
      </div>
      {error || items.length === 0 ? (
        <Card><Alert tone="warn">Şu an internetten sipariş alınamıyor. Lütfen bizi telefonla arayın.</Alert></Card>
      ) : (
        <PublicOrderForm items={items} />
      )}
    </main>
  );
}
