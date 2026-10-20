import { describe, expect, it } from "vitest";
import { headerField, logoFirmsFromSheet, padDigits, parseLogoPaste, plannedFills, taxConflict, type MatchCandidate } from "./logo-firms";

const HEAD = "Müşteri Kodu\tTipi (1: Bireysel / 2: Kurumsal)\tMüşteri Aktif / Pasif\tMüşteri Ünvanı\tMüşteri Ekran Adı\tMüşteri Liste Adı\tÜlke\tŞehir\tİlçe\tAdres\tTelefon\tMüşteri Vkn - Tckn\tVergi Dairesi\tBakiye\tFirma Bakiye\tPara Birimi\tAçılış Bakiye Tarihi\tKategori\tAçıklama\tE Posta";

describe("İşbaşı cari listesi okuma (F-28)", () => {
  it("başlıklar", () => {
    expect(headerField("Müşteri Kodu")).toBe("code");
    expect(headerField("Tipi (1: Bireysel / 2: Kurumsal)")).toBe("tip");
    expect(headerField("Müşteri Vkn - Tckn")).toBe("vkn");
    expect(headerField("Müşteri Ünvanı")).toBe("unvan");
    expect(headerField("E Posta")).toBe("eposta");
    expect(headerField("Bakiye")).toBeNull();
  });
  it("yapıştırılan metin", () => {
    const text = [HEAD,
      "0000000000000002\t2\tAktif\tAAT MAKİNA A.Ş.\tAAT\tAAT\tTürkiye\tKocaeli\t\t\t\t0010400968\tYENİKAPI VD\t6.120,00\t6.120,00\tTL\t01.01.2026\t\t\t",
      "0000000000000058\t1\tPasif\tAHMET AKKAŞ\t\t\tTürkiye\t\t\t\t0532 111 22 33\t26909484406\tALEMDAR\t0\t0\tTL\t\t\t\tAhmet@Ornek.com",
      ""].join("\r\n");
    const r = parseLogoPaste(text);
    expect(r).toHaveLength(2);
    expect(r[0]).toMatchObject({ code: "0000000000000002", tip: "kurumsal", aktif: true, unvan: "AAT MAKİNA A.Ş.", sehir: "Kocaeli", ilce: null, vkn: "0010400968", vd: "YENİKAPI VD" });
    expect(r[1]).toMatchObject({ tip: "bireysel", aktif: false, telefon: "0532 111 22 33", eposta: "ahmet@ornek.com", row: 3 });
  });
  it("başlıksız metin boş döner", () => {
    expect(parseLogoPaste("0000000000000002\t2\tAktif")).toEqual([]);
  });
  it("Excel sayıya çevirmişse sıfırlar tamamlanır", () => {
    expect(padDigits("2", 16)).toBe("0000000000000002");
    expect(padDigits("ABC1", 16)).toBe("ABC1");
    const r = logoFirmsFromSheet([{ row: "2", "müşteri_kodu": "43", "müşteri_ünvanı": "AC MANİFOLD", "müşteri_vkn_-_tckn": "31721015" }]);
    expect(r[0].code).toBe("0000000000000043");
    expect(r[0].vkn).toBe("0031721015");
    const r2 = logoFirmsFromSheet([{ row: "2", "müşteri_kodu": "2", "müşteri_ünvanı": "AAT", "müşteri_vkn_-_tckn": "10400968" }]);
    expect(r2[0].vkn).toBe("0010400968");
    const r3 = logoFirmsFromSheet([{ row: "2", "müşteri_kodu": "2", "müşteri_ünvanı": "AAT", "müşteri_vkn_-_tckn": "310400968" }]);
    expect(r3[0].vkn).toBe("0310400968");
  });
});

describe("doldurulacak alanlar", () => {
  const firm = parseLogoPaste([HEAD, "1\t2\tAktif\tX LTD\t\t\t\tKocaeli\tKartepe\tAdres 1\t\t1234567890\tALEMDAR\t\t\t\t\t\t\tx@y.com"].join("\n"))[0];
  const cand: MatchCandidate = { id: "a", code: "M1", name: "X", legal_title: null, tax_no: null, tax_office: null, phone: null, city: null,
    district: "Başiskele", address: null, email: null, channel: "kurumsal", logo_code: null };
  it("yalnızca boş alanlar", () => {
    expect(plannedFills(firm, cand, true)).toEqual(["vergi no", "vergi dairesi", "unvan", "il", "adres", "e-posta"]);
    expect(plannedFills(firm, cand, false)).not.toContain("vergi no");
  });
  it("farklı VKN uyarısı", () => {
    expect(taxConflict(firm, { ...cand, tax_no: "9876543217" })).toBe(true);
    expect(taxConflict(firm, { ...cand, tax_no: "1234567890" })).toBe(false);
  });
});
