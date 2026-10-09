import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, PageHeader } from "@/components/ui/card";
import { DealerCustomers, type DealerCustomer } from "@/components/customers/dealer-customers";

export const metadata = { title: "Müşterilerim" };

/** Bayinin kendi müşteri listesi (D-059): yalnızca bu bayi ve merkez personeli görür */
export default async function MyCustomersPage() {
  const ctx = await requirePermission("dealerCustomers");
  if (!ctx.customerId) return <Alert>Hesabınız bir bayi kartına bağlı değil. Yöneticinize başvurun.</Alert>;
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from("customers")
    .select("id, code, name, phone, address, note, latitude, longitude, active")
    .eq("owner_dealer_id", ctx.customerId)
    .order("active", { ascending: false })
    .order("name");
  return (
    <div className="space-y-4">
      <PageHeader
        title="Müşterilerim"
        subtitle="Yalnızca siz ve merkez görür. Kendi müşterinize kendiniz teslim edecekseniz sipariş onaysız açılır."
        actions={<Link href="/siparisler/yeni" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Yeni sipariş</Link>}
      />
      <DealerCustomers rows={(data ?? []) as DealerCustomer[]} />
    </div>
  );
}
