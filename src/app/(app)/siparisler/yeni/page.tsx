import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { OrderForm, type OrderFormValue } from "@/components/orders/order-form";
import { loadAssignees, loadOrderCustomers, loadOrderProducts } from "@/lib/orders";
import { todayISO } from "@/lib/format";

export const metadata = { title: "Yeni sipariş" };

export default async function NewOrderPage({ searchParams }: { searchParams: Promise<{ musteri?: string }> }) {
  const ctx = await requirePermission("orders");
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const isDealer = ctx.role === "bayi";
  const [products, customers, assignees] = await Promise.all([
    loadOrderProducts(supabase, ctx.businessId),
    loadOrderCustomers(supabase, ctx.businessId), // bayi için RLS yalnızca kendi kartını döndürür
    isDealer ? Promise.resolve([]) : loadAssignees(supabase, ctx.businessId),
  ]);
  const fixed = isDealer ? customers.find((c) => c.id === ctx.customerId) ?? null : null;
  const preset = !isDealer && sp.musteri ? customers.find((c) => c.id === sp.musteri) ?? null : null;
  const initial: OrderFormValue | null = preset
    ? { id: crypto.randomUUID(), customerId: preset.id, deliveryDate: todayISO(), assignee: preset.defaultAssignee, address: preset.address ?? "", note: "", items: [] }
    : null;
  return (
    <div>
      <PageHeader title="Yeni sipariş" />
      <OrderForm products={products} customers={isDealer ? [] : customers} assignees={assignees} initial={initial} fixedCustomer={fixed} isNew />
    </div>
  );
}
