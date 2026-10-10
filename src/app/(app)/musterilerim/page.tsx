import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, PageHeader } from "@/components/ui/card";
import { DealerCustomers, type DealerCustomer } from "@/components/customers/dealer-customers";
import { RequestList, type CustomerRequest } from "@/components/customers/dealer-requests";

export const metadata = { title: "Müşterilerim" };

/** Bayinin kendi müşteri listesi (D-059): yalnızca bu bayi ve merkez personeli görür */
export default async function MyCustomersPage() {
  const ctx = await requirePermission("dealerCustomers");
  if (!ctx.customerId) return <Alert>Hesabınız bir bayi kartına bağlı değil. Yöneticinize başvurun.</Alert>;
  const supabase = await supabaseServer();
  const [{ data }, { data: reqs }] = await Promise.all([
    supabase
      .from("customers")
      .select("id, code, name, phone, address, note, latitude, longitude, active")
      .eq("owner_dealer_id", ctx.customerId)
      .order("active", { ascending: false })
      .order("name"),
    supabase
      .from("customer_requests")
      .select("id, customer_id, data, status, requested_at, decided_at, decision_note")
      .eq("dealer_id", ctx.customerId)
      .order("requested_at", { ascending: false })
      .limit(30),
  ]);
  const rows = (data ?? []) as DealerCustomer[];
  // Bekleyenlerin tamamı + sonuçlanan son 5 öneri
  const all = (reqs ?? []) as CustomerRequest[];
  const requests = [...all.filter((r) => r.status === "bekliyor"), ...all.filter((r) => r.status !== "bekliyor").slice(0, 5)];
  return (
    <div className="space-y-4">
      <PageHeader
        title="Müşterilerim"
        subtitle="Yalnızca siz ve merkez görür; merkez değişiklik yapamaz, yalnızca önerir. Kendi müşterinize kendiniz teslim edecekseniz sipariş onaysız açılır."
        actions={<Link href="/siparisler/yeni" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Yeni sipariş</Link>}
      />
      <RequestList rows={requests} mode="dealer" currentById={Object.fromEntries(rows.map((r) => [r.id, r]))} />
      <DealerCustomers rows={rows} />
    </div>
  );
}
