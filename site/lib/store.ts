// SPDX-License-Identifier: GPL-3.0-or-later

// PairDesk in the Microsoft Store.
export const STORE_ID = "9MVC6369HWRJ";
/** The Store's web page: for phones, Macs, Linux and anyone without the Store app. */
export const STORE_WEB = `https://apps.microsoft.com/detail/${STORE_ID.toLowerCase()}`;
/** Opens the Microsoft Store app itself on the product page (Windows only). */
export const STORE_APP = `ms-windows-store://pdp/?productid=${STORE_ID}`;

/** True on a Windows computer, which always has the Store app. */
export function isWindows(): boolean {
  const nav = navigator as Navigator & { userAgentData?: { platform?: string } };
  const platform = nav.userAgentData?.platform ?? navigator.platform ?? "";
  return /^Win/i.test(platform) || /Windows NT/i.test(navigator.userAgent);
}
