import { describe, expect, it } from "vitest";
import { initials, matchRank, rankCustomers, searchNorm } from "./customer-search";

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
});
