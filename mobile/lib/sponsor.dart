// SPDX-License-Identifier: GPL-3.0-or-later
// Where people can support PairDesk. Shown only in the builds made for
// GitHub (the same ones that update themselves): Google Play and the
// App Store don't allow links to outside donations, and F-Droid builds
// stay free of them too.

import 'update_check.dart';

const sponsorLinks = <({String name, String note, String url})>[
  (name: 'GitHub Sponsors', note: 'Monthly or one time', url: 'https://github.com/sponsors/sandunMadhushan'),
  (name: 'Patreon', note: 'Monthly support', url: 'https://www.patreon.com/sandunMadhushan'),
  (name: 'Buy Me a Coffee', note: 'One time, no sign-up', url: 'https://buymeacoffee.com/sandunhmadhushan'),
];

bool get showSponsor => updatesFrom == 'github';
