// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata } from "next";
import DocPage from "@/components/DocPage";
import { page } from "@/lib/seo";

export const metadata: Metadata = page({
  title: "Privacy policy",
  description:
    "PairDesk collects no personal data and has no account. Your phone talks to your computer over an encrypted connection, directly or through a relay that can't read it.",
  path: "/privacy/",
});

export default function Privacy() {
  return (
    <DocPage>
      <h1 className="display">Privacy policy</h1>
      <p className="mt-4 text-[0.95rem] !text-slate">
        Applies to the PairDesk app for Android and the PairDesk program for Windows and Linux. Last updated 2
        November 2026.
      </p>

      <h2>In short</h2>
      <p>
        PairDesk doesn&apos;t collect, store or share any personal data. There is no PairDesk account. Your phone and
        your computer talk to each other directly, or, when they can&apos;t reach each other, through a relay that
        only passes their encrypted connection along.
      </p>

      <h2>What stays on your devices</h2>
      <ul>
        <li>
          <b>Pairing keys.</b> When you pair, the phone and the computer each keep the other&apos;s public key and
          their own private key, so they can recognise each other later. They never leave the devices.
        </li>
        <li>
          <b>Names and addresses.</b> The phone remembers each paired computer&apos;s name and network addresses; the
          computer remembers each paired phone&apos;s name. Both are shown only to you.
        </li>
        <li>
          <b>Settings.</b> Your buttons, shortcuts and choices are saved on the device you made them on.
        </li>
      </ul>

      <h2>What travels between your phone and computer</h2>
      <p>
        Touches, key presses, the screen picture when you view it, sound when you listen or talk, clipboard text and
        files you choose to send. All of it goes between your two devices over an encrypted connection (directly, or
        through the relay described below, which can&apos;t read it), and none of it is recorded. Received files are
        saved in the Downloads/PairDesk folder of the receiving device.
      </p>
      <p>
        <b>Windows, with &ldquo;Sign-in screen and admin prompts&rdquo; turned on:</b> a copy of the computer&apos;s
        pairing keys and the list of paired phones is kept in a folder only Windows itself and administrators can
        read, so paired phones can reach the sign-in screen. Turning the option off deletes it.
      </p>

      <h2>Network connections PairDesk makes</h2>
      <ul>
        <li>
          <b>Between your devices</b>, on your local network, or through <a href="https://tailscale.com">Tailscale</a>{" "}
          if you installed it yourself. PairDesk doesn&apos;t send anything to Tailscale; Tailscale&apos;s own privacy
          policy covers Tailscale.
        </li>
        <li>
          <b>The PairDesk relay</b>, when the phone can&apos;t reach the computer directly (another network, no
          Tailscale). The computer keeps a connection open to the relay (by default{" "}
          <code>relay.pairdesk.madhushan.me</code>), and a phone that can&apos;t reach it directly connects through it.
          The connection is encrypted end to end between your phone and your computer: the relay can&apos;t see the
          screen, what you type, files or sound. It sees the two IP addresses, a random id for the computer and how
          much data passes, keeps that only in a short service log, and stores nothing else. You can turn the relay
          off, or use your own, under <i>Remote access</i> on the computer.
        </li>
        <li>
          <b>Update checks.</b> Once a day the computer program (and the Android app downloaded from GitHub) reads a
          small file from GitHub Releases to see whether a newer version exists. Like any web request, this shows
          GitHub your IP address. You can turn it off in PairDesk&apos;s settings on the computer. Copies from the
          Microsoft Store, Flathub or F-Droid don&apos;t do this; the store updates them.
        </li>
      </ul>
      <p className="mt-4">
        The PairDesk apps contain no analytics, advertising or crash-reporting code.
      </p>

      <h2>This website</h2>
      <p>
        The website counts visits with Vercel Web Analytics, which has no cookies and doesn&apos;t follow you from site
        to site. It records which pages are opened, roughly where from (country), and the browser and device type, so
        I can see whether the site is useful. It doesn&apos;t record your IP address in a form that identifies you, and
        it never sees pairing links: they are kept in the part of the address after the <code>#</code>, which
        browsers don&apos;t send. The download buttons also ask GitHub which version is the latest, which shows GitHub
        your IP address.
      </p>

      <h2>Permissions</h2>
      <ul>
        <li>
          <b>Camera</b> (phone): only to scan the pairing code. Nothing is recorded.
        </li>
        <li>
          <b>Local network</b> (phone): to find and reach your computer.
        </li>
        <li>
          <b>Microphone</b> (phone): only while you talk to the computer. Your voice goes to your computer and is
          played there, never recorded.
        </li>
        <li>
          <b>Fingerprint or screen lock</b> (phone, optional): to lock the app. Android handles it; PairDesk never
          sees your fingerprint.
        </li>
        <li>
          <b>Screen and input</b> (computer): to show the screen to your phone and carry out its touches and key
          presses. On Wayland desktops you approve this in the desktop&apos;s own dialog.
        </li>
        <li>
          <b>Sound and microphone</b> (computer): to let your phone hear what the computer plays, and its microphone
          if you allow that in PairDesk&apos;s settings (off by default). Nothing is recorded.
        </li>
      </ul>

      <h2>Children</h2>
      <p>PairDesk is a general-purpose tool and doesn&apos;t knowingly collect anything from anyone, including children.</p>

      <h2>Changes and contact</h2>
      <p>
        If this policy changes, the new version will be published on this page with a new date. Questions:{" "}
        <a href="mailto:contact@madhushan.me">contact@madhushan.me</a> or{" "}
        <a href="https://github.com/sandunMadhushan/pairdesk/issues">GitHub issues</a>.
      </p>
    </DocPage>
  );
}
