import { describe, expect, it } from "vitest";
import { mobileIntl, smsLink, TEMPLATES, whatsappLink } from "./messages";

describe("müşteri mesajı (M-27)", () => {
  it("cep numarası", () => {
    expect(mobileIntl("0540 898 41 61")).toBe("905408984161");
    expect(mobileIntl("+90 (532) 111 22 33")).toBe("905321112233");
    expect(mobileIntl("5321112233")).toBe("905321112233");
    expect(mobileIntl("0262 373 51 52")).toBeNull(); // sabit hat
    expect(mobileIntl(null)).toBeNull();
  });
  it("bağlantılar", () => {
    expect(whatsappLink("905321112233", "a b")).toBe("https://wa.me/905321112233?text=a%20b");
    expect(smsLink("905321112233", "x")).toBe("sms:+905321112233?&body=x");
  });
  it("taslaklar", () => {
    expect(TEMPLATES.tanitim.text).toContain("https://alkasu.vercel.app/giris");
    expect(TEMPLATES.hatirlatma.text.endsWith("Bu otomatik bir bilgilendirme mesajıdır.")).toBe(true);
  });
});
