import { describe, expect, it } from "vitest";
import { shareText, smsUrl, whatsappUrl } from "./share";

describe("uygulamayı paylaş (M-30)", () => {
  const text = shareText("https://alkasu.vercel.app/siparis-ver");
  it("mesaj bağlantıyı içerir", () => {
    expect(text).toContain("https://alkasu.vercel.app/siparis-ver");
  });
  it("WhatsApp ve SMS bağlantıları metni kodlar", () => {
    expect(whatsappUrl("a b&c")).toBe("https://wa.me/?text=a%20b%26c");
    expect(smsUrl("a b")).toBe("sms:?&body=a%20b");
    expect(decodeURIComponent(whatsappUrl(text).split("text=")[1]!)).toBe(text);
  });
});
