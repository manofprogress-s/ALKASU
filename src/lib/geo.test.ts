import { describe, expect, it } from "vitest";
import { directionsUrl, isShortMapsLink, locationInput, parseLocation, toLatLng } from "./geo";

describe("konum", () => {
  it("düz koordinat", () => {
    expect(parseLocation("40.7651, 29.9408")).toEqual({ lat: 40.7651, lng: 29.9408 });
    expect(parseLocation("40.7651 29.9408")).toEqual({ lat: 40.7651, lng: 29.9408 });
    expect(parseLocation("40,7651; 29,9408")).toEqual({ lat: 40.7651, lng: 29.9408 });
  });
  it("Google Maps bağlantıları", () => {
    expect(parseLocation("https://www.google.com/maps/place/Kartepe/@40.7531,30.0212,15z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d40.7512345!4d30.0234567")).toEqual({ lat: 40.751235, lng: 30.023457 });
    expect(parseLocation("https://www.google.com/maps/@40.7531,30.0212,15z")).toEqual({ lat: 40.7531, lng: 30.0212 });
    expect(parseLocation("https://maps.google.com/?q=40.76,29.94")).toEqual({ lat: 40.76, lng: 29.94 });
    expect(parseLocation("https://www.google.com/maps/search/?api=1&query=40.76%2C29.94")).toEqual({ lat: 40.76, lng: 29.94 });
  });
  it("geçersiz girdiler", () => {
    expect(parseLocation("")).toBeNull();
    expect(parseLocation("Kocaeli İzmit")).toBeNull();
    expect(parseLocation("120, 30")).toBeNull();
    expect(toLatLng(null, 3)).toBeNull();
  });
  it("kısa bağlantı ve yol tarifi", () => {
    expect(isShortMapsLink("https://maps.app.goo.gl/abc123")).toBe(true);
    expect(isShortMapsLink("https://www.google.com/maps/@1,2")).toBe(false);
    expect(directionsUrl({ lat: 40.1, lng: 29.2 })).toBe("https://www.google.com/maps/dir/?api=1&destination=40.1,29.2");
  });
});

describe("paylaşılan metinden konum (saha hatası 21.10)", () => {
  it("yer adı + kısa bağlantı", () => {
    expect(locationInput("Alay Ticaret\nhttps://maps.app.goo.gl/AbC123?g_st=iw")).toEqual({ point: null, link: "https://maps.app.goo.gl/AbC123?g_st=iw" });
    expect(locationInput("Şuraya bak: https://g.co/kgs/xYz9.")).toEqual({ point: null, link: "https://g.co/kgs/xYz9" });
  });
  it("metin içinde uzun bağlantı veya koordinat", () => {
    expect(locationInput("Konum https://www.google.com/maps/@40.7531,30.0212,15z burada").point).toEqual({ lat: 40.7531, lng: 30.0212 });
    expect(locationInput("Koordinat: 40.765123, 29.940812").point).toEqual({ lat: 40.765123, lng: 29.940812 });
    expect(locationInput("40.76, 29.94").point).toEqual({ lat: 40.76, lng: 29.94 });
  });
  it("konum yoksa boş", () => {
    expect(locationInput("Kartepe Köseköy")).toEqual({ point: null, link: null });
    expect(isShortMapsLink("https://g.co/kgs/abc")).toBe(true);
  });
});
