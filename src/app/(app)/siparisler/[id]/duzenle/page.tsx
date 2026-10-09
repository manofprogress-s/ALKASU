import { notFound, redirect } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { OrderForm } from "@/components/orders/order-form";
import { dealerOrderSetup, loadAssignees, loadDealerNames, loadOrderCustomers, loadOrderProducts, type Assignee, type Dealer } from "@/lib/orders";

export default async function EditOrderPage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("orders");
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: o } = await supabase
    .from("orders")
    .select("id, no, customer_id, dealer_customer_id, customers!orders_customer_id_fkey(owner_dealer_id), delivery_date, assignee, address, note, status, order_items(product_id, unit_id, qty, unit_price, line_no)")
    .eq("id", id)
    .maybeSingle();
  if (!o) notFound();
  const isSelf = ctx.role === "bayi" || ctx.role === "musteri"; // kendi adına sipariş
  const owner = (o.customers as unknown as { owner_dealer_id: string | null } | null)?.owner_dealer_id ?? null;
  const mine = o.customer_id === ctx.customerId || (ctx.role === "bayi" && !!ctx.customerId && owner === ctx.customerId);
  const deliveredByOther = !!o.dealer_customer_id && o.dealer_customer_id !== ctx.customerId;
  if (!["acik", "onay_bekliyor"].includes(o.status) || (isSelf && (!mine || deliveredByOther))) {
    redirect(`/siparisler/${id}`);
  }
  const [products, customers, assignees, dealers] = await Promise.all([
    loadOrderProducts(supabase, ctx.businessId),
    loadOrderCustomers(supabase, ctx.businessId),
    isSelf ? Promise.resolve([] as Assignee[]) : loadAssignees(supabase, ctx.businessId),
    ctx.role === "bayi" ? loadDealerNames(supabase, ctx.businessId) : Promise.resolve([] as Dealer[]),
  ]);
  const dealer = ctx.role === "bayi" ? dealerOrderSetup(customers, dealers, ctx.customerId) : null;
  const items = ((o.order_items ?? []) as { product_id: string; unit_id: string; qty: number; unit_price: number; line_no: number }[])
    .sort((a, b) => a.line_no - b.line_no)
    .map((i) => ({ productId: i.product_id, unitId: i.unit_id, qty: i.qty, unitPrice: Number(i.unit_price) }));
  return (
    <div>
      <PageHeader title={`Sipariş #${o.no} düzenle`} />
      <OrderForm
        products={products}
        customers={dealer ? dealer.customers : isSelf ? [] : customers}
        assignees={assignees}
        fixedCustomer={ctx.role === "musteri" ? customers.find((c) => c.id === ctx.customerId) ?? null : null}
        dealerMode={dealer?.dealerMode}
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
