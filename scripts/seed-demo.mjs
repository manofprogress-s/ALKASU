// Demo ortamı verisi (T-017). Kurgusal marka/ürün/müşteri adlarıyla bir işletme kurar.
// Kullanım:  DEMO_PASSWORD=... npm run seed:demo      (.env.local'daki Supabase bilgilerini kullanır)
// Yalnızca DEMO projesinde çalıştırın; canlı projede çalıştırmayın.
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
const password = process.env.DEMO_PASSWORD;
const domain = process.env.DEMO_EMAIL_DOMAIN ?? "demo.alkasu.local";
if (!url || !anon || !service || !password) {
  console.error("NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY ve DEMO_PASSWORD gerekli");
  process.exit(1);
}
if (password.length < 10) {
  console.error("DEMO_PASSWORD en az 10 karakter olmalı");
  process.exit(1);
}

const admin = createClient(url, service, { auth: { persistSession: false } });
const USERS = [
  { key: "yonetici", email: `yonetici@${domain}`, name: "Demo Yönetici" },
  { key: "satis", email: `satis@${domain}`, name: "Demo Satış" },
  { key: "depo", email: `depo@${domain}`, name: "Demo Depo" },
  { key: "izleyici", email: `izleyici@${domain}`, name: "Demo İzleyici" },
];

async function ensureUser(email) {
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (created.data?.user) return created.data.user.id;
  const { data } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  const u = data.users.find((x) => x.email === email);
  if (!u) throw new Error(`Kullanıcı oluşturulamadı: ${email} (${created.error?.message})`);
  await admin.auth.admin.updateUserById(u.id, { password });
  return u.id;
}

async function as(email) {
  const c = createClient(url, anon, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return c;
}

async function rpc(client, fn, args) {
  const { data, error } = await client.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

const ids = {};
for (const u of USERS) ids[u.key] = await ensureUser(u.email);

// İşletme (varsa yeniden kullan)
let { data: existing } = await admin.from("memberships").select("business_id").eq("user_id", ids.yonetici).maybeSingle();
let businessId = existing?.business_id;
if (!businessId) {
  businessId = await rpc(admin, "create_business", { p_name: "Alay Ticaret (DEMO)", p_admin_user: ids.yonetici, p_admin_name: "Demo Yönetici" });
}
for (const u of USERS.slice(1)) await rpc(admin, "add_member", { p_business: businessId, p_user: ids[u.key], p_role: u.key, p_name: u.name });

const y = await as(USERS[0].email);
const rows = [
  ["BK-DP", "Dağpınarı Boş Damacana", "Dağpınarı", "Boş kap", "Adet", "", "", "", "", "", "", "20", "", "40", "", "H", "", "", "E"],
  ["DM-DP", "Dağpınarı 19 L Damacana", "Dağpınarı", "Damacana", "Damacana", "8690000100019", "110", "", "", "", "", "1", "70", "60", "15", "E", "250", "BK-DP", "H"],
  ["BK-KS", "Kaynaksu Boş Damacana", "Kaynaksu", "Boş kap", "Adet", "", "", "", "", "", "", "20", "", "25", "", "H", "", "", "E"],
  ["DM-KS", "Kaynaksu 19 L Damacana", "Kaynaksu", "Damacana", "Damacana", "8690000200019", "95", "", "", "", "", "1", "60", "40", "10", "E", "200", "BK-KS", "H"],
  ["SU-05", "Dağpınarı 0,5 L Su", "Dağpınarı", "Su", "Şişe", "8690000100050", "8", "6", "45", "24", "170", "1", "4.6", "480", "96", "H", "", "", "H"],
  ["SU-15", "Dağpınarı 1,5 L Su", "Dağpınarı", "Su", "Şişe", "8690000100150", "15", "6", "85", "", "", "1", "9", "180", "36", "H", "", "", "H"],
  ["SU-5L", "Kaynaksu 5 L Su", "Kaynaksu", "Su", "Bidon", "8690000200500", "40", "", "", "4", "150", "1", "25", "60", "12", "H", "", "", "H"],
  ["MS-02", "Serinsu Maden Suyu 200 ml", "Serinsu", "Maden suyu", "Şişe", "8690000300200", "12", "6", "65", "24", "250", "1", "6.5", "240", "48", "H", "", "", "H"],
  ["GZ-25", "Gazoz Usta 250 ml", "Gazoz Usta", "Meşrubat", "Şişe", "8690000400250", "18", "", "", "24", "400", "20", "11", "96", "24", "H", "", "", "H"],
];
const headers = ["urun_kodu", "urun_adi", "marka", "kategori", "temel_birim", "barkod", "satis_fiyati", "paket_icerik", "paket_satis_fiyati",
  "koli_icerik", "koli_satis_fiyati", "kdv_orani", "alis_fiyati", "acilis_stogu", "kritik_stok", "depozitolu", "depozito_tutari",
  "bos_kap_urun_kodu", "bos_kap_mi"];
const productRows = rows.map((r, i) => {
  const o = { row: String(i + 2) };
  headers.forEach((h, j) => (o[h] = r[j]));
  return o;
});
const imp = await rpc(y, "import_products", { p_business: businessId, p_rows: productRows, p_dry_run: false });
console.log("Ürünler:", imp.summary);

await rpc(y, "import_customers", {
  p_business: businessId,
  p_customers: [
    { row: "2", musteri_kodu: "M001", ad_unvan: "Yıldız Market", telefon: "05320000001", kredi_limiti: "5000", acilis_bakiyesi: "1250" },
    { row: "3", musteri_kodu: "M002", ad_unvan: "Çınar Kafe", telefon: "05320000002", kredi_limiti: "3000", acilis_bakiyesi: "420.5" },
    { row: "4", musteri_kodu: "M003", ad_unvan: "Ayşe Demir (ev)", telefon: "05320000003", adres: "Örnek Mah. 1. Sok. No:5", kredi_limiti: "500" },
    { row: "5", musteri_kodu: "M004", ad_unvan: "Güneş Ofis", telefon: "05320000004", limitsiz: "E" },
    { row: "6", musteri_kodu: "M005", ad_unvan: "Mehmet Kaya (ev)", telefon: "05320000005" },
  ],
  p_containers: [
    { row: "2", musteri_kodu: "M001", dolu_urun_kodu: "DM-DP", kap_adedi: "6", odenen_depozito: "1500" },
    { row: "3", musteri_kodu: "M003", dolu_urun_kodu: "DM-DP", kap_adedi: "2", odenen_depozito: "500" },
    { row: "4", musteri_kodu: "M004", dolu_urun_kodu: "DM-KS", kap_adedi: "10", odenen_depozito: "2000" },
  ],
  p_dry_run: false,
});

// Bugünün birkaç satışı (satış personeli olarak)
const s = await as(USERS[1].email);
const { data: prods } = await y.from("products").select("id, code, deposit_amount, product_units(id, name, factor, price, active)").eq("business_id", businessId);
const { data: custs } = await y.from("customers").select("id, code").eq("business_id", businessId);
const P = Object.fromEntries(prods.map((p) => [p.code, p]));
const C = Object.fromEntries(custs.map((c) => [c.code, c.id]));
const unit = (code, name) => P[code].product_units.find((u) => u.active && (name ? u.name === name : u.factor === 1));
const line = (code, name, qty) => { const u = unit(code, name); return { product_id: P[code].id, unit_id: u.id, qty, unit_price: Number(u.price) }; };
const sale = async (client, items, payments, extra = {}) =>
  rpc(client, "complete_sale", { p_business: businessId, p: { id: randomUUID(), items, payments, ...extra } });

await sale(s, [line("SU-05", "Koli", 2)], [{ method: "nakit", amount: 340 }]);
await sale(s, [line("DM-DP", null, 2)], [{ method: "nakit", amount: 220 }]);
await sale(s, [line("MS-02", "Paket", 1), line("GZ-25", null, 3)], [{ method: "pos", amount: 119 }]);
await sale(s, [line("DM-DP", null, 3)], [{ method: "veresiye", amount: 830 }], {
  customer_id: C.M003, deposits: [{ product_id: P["DM-DP"].id, empty_returned: 1 }],
}).catch((e) => console.log("(beklenen) limit:", e.message));
await sale(y, [line("DM-KS", null, 5)], [{ method: "veresiye", amount: 475 }], { customer_id: C.M004 });
await sale(s, [line("SU-15", "Paket", 2), line("SU-5L", null, 1)], [{ method: "nakit", amount: 100 }, { method: "pos", amount: 110 }]);
await rpc(s, "record_customer_payment", { p_business: businessId, p: { id: randomUUID(), customer_id: C.M001, method: "nakit", amount: 500 } });

// Depo: fiyat onayı bekleyen bir mal kabul
const d = await as(USERS[2].email);
await rpc(d, "receive_goods", { p_business: businessId, p: { id: randomUUID(), doc_no: "IRS-DEMO-1",
  items: [{ product_id: P["SU-05"].id, unit_id: unit("SU-05", "Koli").id, qty: 10, free_qty: 1 }],
  empties: [{ product_id: P["BK-DP"].id, qty: 10 }] } });

console.log("\nDemo hazır. Giriş bilgileri (şifre: DEMO_PASSWORD):");
for (const u of USERS) console.log(`  ${u.key.padEnd(9)} ${u.email}`);
