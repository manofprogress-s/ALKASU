import { notFound, redirect } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { OrderForm } from "@/components/orders/order-form";
import { loadAssignees, loadOrderCustomers, loadOrderProducts, type Assignee } from "@/lib/orders";

export default async function EditOrderPage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("orders");
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: o } = await supabase
    .from("orders")
    .select("id, no, customer_id, dealer_customer_id, delivery_date, assignee, address, note, status, order_items(product_id, unit_id, qty, unit_price, line_no)")
    .eq("id", id)
    .maybeSingle();
  if (!o) notFound();
  const isSelf = ctx.role === "bayi" || ctx.role === "musteri"; // kendi adına sipariş
  if (!["acik", "onay_bekliyor"].includes(o.status) || (isSelf && (o.dealer_customer_id || o.customer_id !== ctx.customerId))) {
    redirect(`/siparisler/${id}`);
  }
  const [products, customers, assignees] = await Promise.all([
    loadOrderProducts(supabase, ctx.businessId),
    loadOrderCustomers(supabase, ctx.businessId),
    isSelf ? Promise.resolve([] as Assignee[]) : loadAssignees(supabase, ctx.businessId),
  ]);
  const items = ((o.order_items ?? []) as { product_id: string; unit_id: string; qty: number; unit_price: number; line_no: number }[])
    .sort((a, b) => a.line_no - b.line_no)
    .map((i) => ({ productId: i.product_id, unitId: i.unit_id, qty: i.qty, unitPrice: Number(i.unit_price) }));
  return (
    <div>
      <PageHeader title={`Sipariş #${o.no} düzenle`} />
      <OrderForm
        products={products}
        customers={isSelf ? [] : customers}
        assignees={assignees}
        fixedCustomer={isSelf ? customers.find((c) => c.id === ctx.customerId) ?? null : null}
        isNew={false}
        initial={{
          id: o.id,
          customerId: o.customer_id,
          deliveryDate: o.delivery_date,
          assignee: o.assignee,
          address: o.address ?? "",
          note: o.note ?? "",
          items,
        }}
      />
    </div>
  );
}
