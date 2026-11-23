// SPDX-License-Identifier: GPL-3.0-or-later

// Where the phone app is published. Fill these in when the app is in the
// stores: /app/ then sends people there, and nothing else needs to change
// (the computer app and the printed links all point at /app/).
export const PLAY_STORE: string | null = null;
export const APP_STORE: string | null = null;

export type Phone = "android" | "ios" | "other";

export function phoneKind(): Phone {
  const ua = navigator.userAgent;
  if (/Android/i.test(ua)) return "android";
  if (/iPhone|iPad|iPod/i.test(ua)) return "ios";
  return "other";
}
