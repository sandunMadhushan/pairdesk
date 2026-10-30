# SPDX-License-Identifier: GPL-3.0-or-later
# The PairDesk relay in a small container. Build from the repository root:
#   docker build -f packaging/relay/Dockerfile -t pairdesk-relay .
#   docker run -d --restart=always -p 443:47900 -p 47900:47900 pairdesk-relay
FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY relay/ .
RUN cargo build --release --locked

FROM scratch
COPY --from=build /src/target/release/pairdesk-relay /pairdesk-relay
ENV RUST_LOG=info
EXPOSE 47900
USER 65534
ENTRYPOINT ["/pairdesk-relay", "--listen", "0.0.0.0:47900"]
