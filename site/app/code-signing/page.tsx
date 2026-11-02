// SPDX-License-Identifier: GPL-3.0-or-later
import type { Metadata } from "next";
import Link from "next/link";
import DocPage from "@/components/DocPage";
import { page } from "@/lib/seo";

export const metadata: Metadata = page({
  title: "Code signing policy",
  description: "How PairDesk's Windows downloads are built from the public source code and signed, and who can sign them.",
  path: "/code-signing/",
});

export default function CodeSigning() {
  return (
    <DocPage>
      <h1 className="display">Code signing policy</h1>
      <p className="mt-6">
        PairDesk has applied for free code signing from the <a href="https://signpath.org">SignPath Foundation</a>,
        with signing by <a href="https://about.signpath.io">SignPath.io</a>. Until then, Windows downloads are not
        signed. Check them against <code>SHA256SUMS.txt</code> on the release page.
      </p>
      <p>
        Signed files are built only by GitHub Actions from this project&apos;s public source code (
        <a href="https://github.com/sandunMadhushan/pairdesk">github.com/sandunMadhushan/pairdesk</a>), and each
        release is approved by hand before it is signed.
      </p>

      <h2>Team roles</h2>
      <ul>
        <li>
          Committers and reviewers: <a href="https://github.com/sandunMadhushan">Sandun Madhushan</a>
        </li>
        <li>
          Approvers: <a href="https://github.com/sandunMadhushan">Sandun Madhushan</a>
        </li>
      </ul>
      <p className="mt-4">Changes from outside contributors are reviewed by a committer before they are merged.</p>

      <h2>Privacy</h2>
      <p>
        This program will not transfer any information to other networked systems unless specifically requested by
        the user or the person installing or operating it, apart from a daily check for new versions on GitHub,
        which can be turned off in PairDesk&apos;s settings, and the optional PairDesk relay, which only passes the
        encrypted connection between your phone and your computer. See the <Link href="/privacy">privacy policy</Link>.
      </p>
    </DocPage>
  );
}
