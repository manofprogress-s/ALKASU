import { redirect } from "next/navigation";
import Link from "next/link";
import { supabaseServer } from "@/lib/supabase/server";
import { sessionUser } from "@/lib/supabase/claims";
import { Alert, Card } from "@/components/ui/card";
import { PublicOrderForm } from "@/components/public/public-order-form";
import { toShopItems, type CatalogRow } from "@/lib/shop";

export const metadata = { title: "Sipariş ver" };
export const dynamic = "force-dynamic";

/** Herkese açık hızlı sipariş + kayıt (D-051, D-069). Giriş yapmış kullanıcı kendi sipariş ekranına gider. */
export default async function PublicOrderPage() {
  const supabase = await supabaseServer();
  if (await sessionUser(supabase)) redirect("/siparisler/yeni");
  const { data, error } = await supabase.rpc("public_catalog");
  const items = toShopItems((data ?? []) as CatalogRow[]);
  return (
    <main className="mx-auto max-w-2xl p-4 pb-16">
      {error || items.length === 0 ? (
        <div className="space-y-4">
          <div className="text-3xl font-extrabold tracking-tight text-brand">ALKASU</div>
          <Card><Alert tone="warn">Şu an internetten sipariş alınamıyor. Lütfen bizi telefonla arayın.</Alert></Card>
          <Link href="/giris" className="text-sm text-brand">Giriş sayfasına dön</Link>
        </div>
      ) : (
        <PublicOrderForm items={items} />
      )}
    </main>
  );
}
