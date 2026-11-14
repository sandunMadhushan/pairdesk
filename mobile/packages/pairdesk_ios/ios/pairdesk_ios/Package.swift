// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
  name: "pairdesk_ios",
  platforms: [.iOS("15.0")],
  products: [.library(name: "pairdesk-ios", targets: ["pairdesk_ios"])],
  dependencies: [],
  targets: [.target(name: "pairdesk_ios", dependencies: [])]
)
