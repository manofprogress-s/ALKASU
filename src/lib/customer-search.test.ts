import { describe, expect, it } from "vitest";
import { initials, matchRank, rankCustomers, rankLocal, rowContainers, rowToOrderCustomer, rowToPosCustomer, searchNorm, type CustomerSearchRow } from "./customer-search";

const list = [
  { name: "TÜRKİYE JOKEY KULÜBÜ DERNEĞİ", code: "K100" },
  { name: "Y.K. Gıda Ltd.Şti.", code: "K101" },
  { name: "GOİS DIŞ TİCARET", code: "K102" },
  { name: "Aliye Yılmazer", code: "K105" },
  { name: "Ali Yılmaz İnşaat", code: "K104" },
  { name: "Ali Yılmaz", code: "K103" },
];
const first = (q: string) => rankCustomers(list, q)[0]?.name;

describe("müşteri araması (M-28)", () => {
  it("norm: Türkçe harf, noktalama, boşluk", () => {
    expect(searchNorm("  GOİS   DIŞ  ")).toBe("gois dis");
    expect(searchNorm("Y.K. Gıda Ltd.Şti.")).toBe("y k gida ltd sti");
    expect(initials("turkiye jokey kulubu dernegi")).toBe("tjkd");
  });
  it("1. tam ad en üstte", () => {
    expect(first("Ali Yılmaz")).toBe("Ali Yılmaz");
    expect(matchRank("Ali Yılmaz", "K103", "ALİ YILMAZ")).toBe(0);
  });
  it("2. kısaltma", () => {
    expect(first("TJK")).toBe("TÜRKİYE JOKEY KULÜBÜ DERNEĞİ");
    expect(first("yk gida")).toBe("Y.K. Gıda Ltd.Şti.");
    expect(first("Y.K.")).toBe("Y.K. Gıda Ltd.Şti.");
  });
  it("3. ortadaki kelime ve farklı sıra", () => {
    expect(first("jokey")).toBe("TÜRKİYE JOKEY KULÜBÜ DERNEĞİ");
    expect(first("kulübü türkiye")).toBe("TÜRKİYE JOKEY KULÜBÜ DERNEĞİ");
  });
  it("4. Türkçe karakter ve büyük/küçük harf", () => {
    expect(first("gois dis")).toBe("GOİS DIŞ TİCARET");
    expect(first("  ali    yilmaz ")).toBe("Ali Yılmaz");
  });
  it("5. benzer adlar ayrışır", () => {
    expect(rankCustomers(list, "ali yılmaz").map((c) => c.name)).toEqual(["Ali Yılmaz", "Ali Yılmaz İnşaat", "Aliye Yılmazer"]);
    expect(matchRank("Aliye Yılmazer", "K105", "ali yılmaz")).toBe(3);
    expect(matchRank("Ali Yılmaz", "K103", "zzz")).toBeNull();
    expect(first("K105")).toBe("Aliye Yılmazer");
  });
  it("bayi kartı yerel aramada da üstte (çevrimdışı)", () => {
    const recent = [
      { name: "İBRAHİM SAĞLAM", code: "A1027", phone: "0541 306 41 95", channel: "perakende" },
      { name: "Sağlam Ticaret (Gürpınar Ev Bayisi)", code: "B001", phone: null, channel: "bayi" },
    ];
    expect(rankLocal(recent, "sağlam").map((c) => c.code)).toEqual(["B001", "A1027"]);
    expect(rankLocal(recent, "0541 306").map((c) => c.code)).toEqual(["A1027"]);
  });
});

describe("arama satırı dönüşümü (M-29, F-37)", () => {
  const row: CustomerSearchRow = {
    id: "c1", code: "B001", name: "Sağlam Ticaret", address: null, phone: null, channel: "bayi", price_list: "bayi",
    default_assignee: null, owner_dealer_id: null, credit_limit: "0", unlimited_credit: true, balance: "1780.00",
    special_prices: { u1: "78.00" }, deposits: { p1: "400.00" }, containers: [{ product_id: "p1", qty: 10, amount: "4000.00" }],
    dealer_hint: null, match_rank: 1, total: 2,
  };
  it("satış ekranı müşterisi: sayılar, özel fiyat ve depozito", () => {
    const c = rowToPosCustomer(row);
    expect(c.balance).toBe(1780);
    expect(c.specialPrices).toEqual({ u1: 78 });
    expect(c.deposits).toEqual({ p1: 400 });
    expect(c.channel).toBe("bayi");
    expect(rowContainers(row)).toEqual([{ customerId: "c1", productId: "p1", qty: 10, amount: 4000 }]);
  });
  it("sipariş müşterisi: bayi ipucu taşınır", () => {
    const o = rowToOrderCustomer({ ...row, channel: "perakende", price_list: null, dealer_hint: { id: "d", code: "B001", name: "Sağlam Ticaret" } });
    expect(o.priceList).toBe("perakende");
    expect(o.dealerHint?.code).toBe("B001");
  });
});
