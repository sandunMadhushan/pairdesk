// SPDX-License-Identifier: GPL-3.0-or-later
//! A reliable, ordered byte stream over UDP ("PDU1"), for direct
//! connections between a phone and this computer.
//!
//! TLS runs inside it exactly as over TCP, with the certificate pinned on the
//! phone, so this layer only has to deliver bytes in order: it doesn't need
//! to be secret or tamper-proof itself. A forged or replayed packet can at
//! worst break the TLS session, and the phone then reconnects.
//!
//! This is a state machine without input or output of its own ("sans-IO"):
//! the caller feeds it packets and the time, and sends what it hands back.
//! The phone has the same code in Dart (`mobile/lib/pairing/direct_conn.dart`);
//! the two must stay in step. Packets (big-endian):
//!
//! ```text
//! 1 PUNCH      token[8] side u8          opening the path (0 phone, 1 computer)
//! 2 PUNCH_ACK  token[8] side u8
//! 3 DATA       token[8] seq u32 bytes    1..=1200 bytes
//! 4 ACK        token[8] next u32 window u16 sack u64
//!              next: first sequence number not yet received; bit i of
//!              sack: next+1+i was received; window: packets that fit
//! 5 FIN        token[8] seq u32          end of the stream (takes a number)
//! 6 PING       token[8]                  answered with an ACK
//! 7 RESET      token[8]                  the stream is abandoned
//! ```

use std::collections::{BTreeMap, VecDeque};
use std::time::{Duration, Instant};

pub const PUNCH: u8 = 1;
pub const PUNCH_ACK: u8 = 2;
pub const DATA: u8 = 3;
pub const ACK: u8 = 4;
pub const FIN: u8 = 5;
pub const PING: u8 = 6;
pub const RESET: u8 = 7;

/// Bytes of data in one packet: small enough for any path, even through
/// tunnels (IPv4 and UDP headers plus ours stay under 1280).
pub const MAX_PAYLOAD: usize = 1200;
/// Packets the receiver keeps out of order or waiting to be read.
const RECV_WINDOW: u32 = 2048;
/// Packets the sender keeps, sent or not, before it stops taking data.
const SEND_BUFFER: usize = 2048;
const INITIAL_CWND: f64 = 16.0;
const MIN_CWND: f64 = 2.0;
const MAX_CWND: f64 = 2048.0;
const INITIAL_RTO: Duration = Duration::from_millis(600);
const MIN_RTO: Duration = Duration::from_millis(200);
const MAX_RTO: Duration = Duration::from_secs(4);
/// Nothing from the other side for this long: the path is gone. (The
/// phone pings every 3 s inside the session, so a live one is never quiet.)
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(20);
/// Something is sent at least this often, keeping NAT mappings open.
const KEEPALIVE: Duration = Duration::from_secs(4);
/// Packets that may leave at once before pacing spreads them out.
const BURST: f64 = 10.0;
/// A sent packet counts as lost once this many later ones have arrived.
const REORDER: u32 = 3;

pub fn header(kind: u8, token: &[u8; 8]) -> Vec<u8> {
    let mut p = Vec::with_capacity(MAX_PAYLOAD + 13);
    p.push(kind);
    p.extend_from_slice(token);
    p
}

/// The packet's kind, if it carries this token.
pub fn kind_of(packet: &[u8], token: &[u8; 8]) -> Option<u8> {
    if packet.len() < 9 || &packet[1..9] != token {
        return None;
    }
    Some(packet[0])
}

fn be32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

struct Segment {
    seq: u32,
    data: Vec<u8>,
    fin: bool,
    sent: Option<Instant>,
    retransmitted: bool,
    acked: bool,
    lost: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Open,
    /// Both ends finished and everything was delivered.
    Closed,
    /// Reset, or the other side went quiet.
    Failed,
}

pub struct Conn {
    token: [u8; 8],
    state: State,
    // Sending.
    queue: VecDeque<Segment>,
    next_seq: u32,
    closing: bool,
    fin_acked: bool,
    cwnd: f64,
    ssthresh: f64,
    srtt: Option<Duration>,
    rttvar: Duration,
    rto: Duration,
    recovery: u32,
    /// When the most recently sent packet that has been acknowledged was
    /// sent. Only packets sent before it can be judged lost.
    rack_sent: Option<Instant>,
    peer_window: u32,
    tokens: f64,
    refilled: Instant,
    last_sent: Instant,
    // Receiving.
    rcv_next: u32,
    early: BTreeMap<u32, (Vec<u8>, bool)>,
    ready: VecDeque<u8>,
    ready_packets: u32,
    peer_finished: bool,
    ack_due: bool,
    last_heard: Instant,
}

impl Conn {
    pub fn new(token: [u8; 8], now: Instant) -> Self {
        Self {
            token,
            state: State::Open,
            queue: VecDeque::new(),
            next_seq: 0,
            closing: false,
            fin_acked: false,
            cwnd: INITIAL_CWND,
            ssthresh: MAX_CWND,
            srtt: None,
            rttvar: Duration::ZERO,
            rto: INITIAL_RTO,
            recovery: 0,
            rack_sent: None,
            peer_window: RECV_WINDOW,
            tokens: BURST,
            refilled: now,
            last_sent: now,
            rcv_next: 0,
            early: BTreeMap::new(),
            ready: VecDeque::new(),
            ready_packets: 0,
            peer_finished: false,
            ack_due: false,
            last_heard: now,
        }
    }

    pub fn token(&self) -> [u8; 8] {
        self.token
    }

    pub fn state(&self) -> State {
        self.state
    }

    /// Room for more data, in bytes.
    pub fn send_space(&self) -> usize {
        if self.closing || self.state != State::Open {
            return 0;
        }
        SEND_BUFFER.saturating_sub(self.queue.len()) * MAX_PAYLOAD
    }

    /// Queues as much of `data` as fits; returns how much.
    pub fn write(&mut self, data: &[u8]) -> usize {
        let room = self.send_space().min(data.len());
        for chunk in data[..room].chunks(MAX_PAYLOAD) {
            self.queue.push_back(Segment {
                seq: self.next_seq,
                data: chunk.to_vec(),
                fin: false,
                sent: None,
                retransmitted: false,
                acked: false,
                lost: false,
            });
            self.next_seq += 1;
        }
        room
    }

    /// No more data from this side.
    pub fn close(&mut self) {
        if self.closing || self.state != State::Open {
            return;
        }
        self.closing = true;
        self.queue.push_back(Segment {
            seq: self.next_seq,
            data: Vec::new(),
            fin: true,
            sent: None,
            retransmitted: false,
            acked: false,
            lost: false,
        });
        self.next_seq += 1;
    }

    /// Abandons the stream; the caller sends the returned packet.
    pub fn reset(&mut self) -> Vec<u8> {
        self.state = State::Failed;
        header(RESET, &self.token)
    }

    /// Bytes received in order and not read yet.
    pub fn read(&mut self, max: usize) -> Vec<u8> {
        let n = max.min(self.ready.len());
        let out: Vec<u8> = self.ready.drain(..n).collect();
        // Window accounting in whole packets, rounded up.
        self.ready_packets = self.ready.len().div_ceil(MAX_PAYLOAD) as u32;
        if n > 0 {
            // A reopening window is worth telling the sender about.
            self.ack_due = true;
        }
        out
    }

    pub fn has_ready(&self) -> bool {
        !self.ready.is_empty()
    }

    /// The other side finished and every byte before its end was read.
    pub fn peer_finished(&self) -> bool {
        self.peer_finished && self.ready.is_empty()
    }

    fn window(&self) -> u32 {
        RECV_WINDOW.saturating_sub(self.early.len() as u32 + self.ready_packets)
    }

    /// Handles one packet that carries this stream's token. Returns false
    /// for anything that isn't part of the stream (PUNCH, junk).
    pub fn on_packet(&mut self, packet: &[u8], now: Instant) -> bool {
        let Some(kind) = kind_of(packet, &self.token) else {
            return false;
        };
        let body = &packet[9..];
        match kind {
            DATA | FIN if body.len() >= 4 => {
                let seq = be32(body);
                let data = &body[4..];
                if kind == DATA && (data.is_empty() || data.len() > MAX_PAYLOAD) {
                    return false;
                }
                self.last_heard = now;
                self.ack_due = true;
                if seq >= self.rcv_next && seq - self.rcv_next < RECV_WINDOW {
                    self.early
                        .entry(seq)
                        .or_insert_with(|| (data.to_vec(), kind == FIN));
                    while let Some((data, fin)) = self.early.remove(&self.rcv_next) {
                        self.rcv_next += 1;
                        if fin {
                            self.peer_finished = true;
                            self.early.clear();
                            break;
                        }
                        self.ready.extend(data);
                    }
                    self.ready_packets = self.ready.len().div_ceil(MAX_PAYLOAD) as u32;
                }
            }
            ACK if body.len() >= 14 => {
                self.last_heard = now;
                let next = be32(body);
                self.peer_window = u16::from_be_bytes([body[4], body[5]]) as u32;
                let sack = u64::from_be_bytes(body[6..14].try_into().unwrap());
                self.on_ack(next, sack, now);
            }
            PING => {
                self.last_heard = now;
                self.ack_due = true;
            }
            RESET => self.state = State::Failed,
            _ => return false,
        }
        self.check_closed();
        true
    }

    fn on_ack(&mut self, next: u32, sack: u64, now: Instant) {
        let mut sample = None;
        let mut newly = 0u32;
        let mut highest = None;
        for seg in self.queue.iter_mut() {
            let covered = seg.seq < next
                || (seg.seq > next
                    && seg.seq - next - 1 < 64
                    && sack & (1u64 << (seg.seq - next - 1)) != 0);
            if covered && !seg.acked {
                seg.acked = true;
                newly += 1;
                if seg.fin {
                    self.fin_acked = true;
                }
                if let (Some(sent), false) = (seg.sent, seg.retransmitted) {
                    sample = Some(now.saturating_duration_since(sent));
                }
                if let Some(sent) = seg.sent {
                    self.rack_sent = Some(self.rack_sent.map_or(sent, |r| r.max(sent)));
                }
            }
            if seg.acked {
                highest = Some(seg.seq);
            }
        }
        while self.queue.front().is_some_and(|s| s.acked) {
            self.queue.pop_front();
        }
        if let Some(rtt) = sample {
            self.update_rtt(rtt);
        }
        for _ in 0..newly {
            if self.cwnd < self.ssthresh {
                self.cwnd += 1.0;
            } else {
                self.cwnd += 1.0 / self.cwnd;
            }
        }
        self.cwnd = self.cwnd.min(MAX_CWND);
        // Packets well behind one that arrived are taken as lost.
        if let (Some(highest), Some(rack)) = (highest, self.rack_sent) {
            let mut loss = false;
            for seg in self.queue.iter_mut() {
                if !seg.acked
                    && !seg.lost
                    && seg.sent.is_some_and(|t| t < rack)
                    && seg.seq + REORDER <= highest
                {
                    seg.lost = true;
                    if seg.seq >= self.recovery {
                        loss = true;
                    }
                }
            }
            if loss {
                self.ssthresh = (self.cwnd / 2.0).max(MIN_CWND);
                self.cwnd = self.ssthresh;
                self.recovery = self.next_seq;
            }
        }
    }

    fn update_rtt(&mut self, rtt: Duration) {
        match self.srtt {
            None => {
                self.srtt = Some(rtt);
                self.rttvar = rtt / 2;
            }
            Some(srtt) => {
                let diff = srtt.abs_diff(rtt);
                self.rttvar = (self.rttvar * 3 + diff) / 4;
                self.srtt = Some((srtt * 7 + rtt) / 8);
            }
        }
        let srtt = self.srtt.unwrap();
        self.rto =
            (srtt + (self.rttvar * 4).max(Duration::from_millis(10))).clamp(MIN_RTO, MAX_RTO);
    }

    fn check_closed(&mut self) {
        if self.state == State::Open
            && self.closing
            && self.fin_acked
            && self.peer_finished
            && self.ready.is_empty()
        {
            self.state = State::Closed;
        }
    }

    fn inflight(&self) -> usize {
        self.queue
            .iter()
            .filter(|s| s.sent.is_some() && !s.acked && !s.lost)
            .count()
    }

    fn refill(&mut self, now: Instant) {
        let srtt = self
            .srtt
            .unwrap_or(Duration::from_millis(100))
            .max(Duration::from_millis(5));
        let rate = self.cwnd * 1.25 / srtt.as_secs_f64();
        let elapsed = now.saturating_duration_since(self.refilled).as_secs_f64();
        self.tokens = (self.tokens + rate * elapsed).min(BURST.max(self.cwnd / 4.0));
        self.refilled = now;
    }

    fn data_packet(&self, seg: &Segment) -> Vec<u8> {
        let mut p = header(if seg.fin { FIN } else { DATA }, &self.token);
        p.extend_from_slice(&seg.seq.to_be_bytes());
        p.extend_from_slice(&seg.data);
        p
    }

    fn ack_packet(&self) -> Vec<u8> {
        let mut sack = 0u64;
        for &seq in self.early.keys() {
            let off = seq - self.rcv_next;
            if (1..=64).contains(&off) {
                sack |= 1u64 << (off - 1);
            }
        }
        let mut p = header(ACK, &self.token);
        p.extend_from_slice(&self.rcv_next.to_be_bytes());
        p.extend_from_slice(&(self.window().min(u16::MAX as u32) as u16).to_be_bytes());
        p.extend_from_slice(&sack.to_be_bytes());
        p
    }

    /// The next packet to send now, if any. Call until it returns None.
    pub fn poll_transmit(&mut self, now: Instant) -> Option<Vec<u8>> {
        if self.state == State::Failed {
            return None;
        }
        if self.ack_due {
            self.ack_due = false;
            self.last_sent = now;
            return Some(self.ack_packet());
        }
        if self.state != State::Open {
            return None;
        }
        self.refill(now);
        if self.tokens >= 1.0 {
            // Lost packets first, then new ones while the window allows.
            let limit = (self.cwnd as usize).min(self.peer_window.max(1) as usize);
            let inflight = self.inflight();
            let pick = if inflight < limit {
                self.queue
                    .iter()
                    .position(|s| s.lost && !s.acked)
                    .or_else(|| self.queue.iter().position(|s| s.sent.is_none()))
            } else {
                None
            };
            if let Some(i) = pick {
                let seg = &mut self.queue[i];
                if seg.sent.is_some() {
                    seg.retransmitted = true;
                }
                seg.lost = false;
                seg.sent = Some(now);
                self.tokens -= 1.0;
                self.last_sent = now;
                return Some(self.data_packet(&self.queue[i]));
            }
        }
        if now.saturating_duration_since(self.last_sent) >= KEEPALIVE {
            self.last_sent = now;
            return Some(header(PING, &self.token));
        }
        None
    }

    /// Retransmission and liveness timers; call at [Self::next_timeout].
    pub fn on_timeout(&mut self, now: Instant) {
        if self.state != State::Open {
            return;
        }
        if now.saturating_duration_since(self.last_heard) >= IDLE_TIMEOUT {
            self.state = State::Failed;
            return;
        }
        let expired = self
            .queue
            .iter()
            .find(|s| !s.acked && !s.lost && s.sent.is_some())
            .is_some_and(|s| now.saturating_duration_since(s.sent.unwrap()) >= self.rto);
        if expired {
            // Everything still out is presumed lost (a whole burst often is)
            // and sent again as the window allows.
            for seg in self.queue.iter_mut() {
                if !seg.acked && seg.sent.is_some() {
                    seg.lost = true;
                }
            }
            self.ssthresh = (self.cwnd / 2.0).max(MIN_CWND);
            self.cwnd = MIN_CWND;
            self.rto = (self.rto * 2).min(MAX_RTO);
            self.recovery = self.next_seq;
        }
    }

    /// When [Self::on_timeout] or [Self::poll_transmit] next has work.
    pub fn next_timeout(&self, now: Instant) -> Instant {
        let mut at = self.last_heard + IDLE_TIMEOUT;
        at = at.min(self.last_sent + KEEPALIVE);
        if let Some(sent) = self
            .queue
            .iter()
            .filter(|s| !s.acked && !s.lost)
            .filter_map(|s| s.sent)
            .min()
        {
            at = at.min(sent + self.rto);
        }
        let limit = (self.cwnd as usize).min(self.peer_window.max(1) as usize);
        let waiting = self.queue.iter().any(|s| s.lost || s.sent.is_none());
        if waiting && self.tokens < 1.0 && self.inflight() < limit {
            at = at.min(now + Duration::from_millis(2));
        }
        at.max(now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two streams joined by a simulated link that loses, reorders and
    /// delays packets. Returns what B received and the simulated time.
    fn run_link(
        data: &[u8],
        loss: f64,
        delay: Duration,
        seed: u64,
    ) -> (Vec<u8>, Duration, State, State) {
        let token = *b"tokentok";
        let start = Instant::now();
        let mut now = start;
        let mut a = Conn::new(token, now);
        let mut b = Conn::new(token, now);
        let mut rng = seed;
        let mut rand = move || {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            (rng % 10_000) as f64 / 10_000.0
        };
        // In flight: (arrival, to_b, packet)
        let mut wire: Vec<(Instant, bool, Vec<u8>)> = Vec::new();
        let mut sent = 0;
        let mut got = Vec::new();
        let step = Duration::from_millis(1);
        for _ in 0..600_000 {
            if sent < data.len() {
                sent += a.write(&data[sent..]);
            } else {
                a.close();
            }
            for (from_a, conn) in [(true, &mut a), (false, &mut b)] {
                while let Some(p) = conn.poll_transmit(now) {
                    if rand() >= loss {
                        let jitter = Duration::from_micros((rand() * 4000.0) as u64);
                        wire.push((now + delay + jitter, from_a, p));
                    }
                }
            }
            let (due, later): (Vec<_>, Vec<_>) = wire.drain(..).partition(|(t, _, _)| *t <= now);
            wire = later;
            for (_, to_b, p) in due {
                if to_b {
                    b.on_packet(&p, now);
                } else {
                    a.on_packet(&p, now);
                }
            }
            got.extend(b.read(usize::MAX));
            if b.peer_finished() {
                b.close();
            }
            a.on_timeout(now);
            b.on_timeout(now);
            if a.state() != State::Open && b.state() != State::Open {
                break;
            }
            now += step;
        }
        (got, now - start, a.state(), b.state())
    }

    fn sample(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i * 7 + i / 1000) as u8).collect()
    }

    #[test]
    fn delivers_in_order_on_a_clean_link() {
        let data = sample(500_000);
        let (got, took, a, b) = run_link(&data, 0.0, Duration::from_millis(20), 1);
        assert_eq!(got, data);
        assert_eq!((a, b), (State::Closed, State::Closed));
        // 500 KB over a 40 ms round trip shouldn't take long.
        assert!(took < Duration::from_secs(2), "{took:?}");
    }

    #[test]
    fn survives_loss_and_reordering() {
        let data = sample(300_000);
        for seed in 1..6 {
            let (got, _, a, b) = run_link(&data, 0.1, Duration::from_millis(30), seed);
            assert_eq!(got.len(), data.len(), "seed {seed}");
            assert!(got == data, "seed {seed}");
            assert_eq!((a, b), (State::Closed, State::Closed), "seed {seed}");
        }
    }

    #[test]
    fn heavy_loss_still_gets_through() {
        let data = sample(60_000);
        let (got, _, _, _) = run_link(&data, 0.3, Duration::from_millis(50), 9);
        assert!(got == data);
    }

    /// A narrow link with a small queue: bursts overflow it and whole runs
    /// of packets are lost, as on a real router or a full socket buffer.
    #[test]
    fn a_bottleneck_that_drops_bursts() {
        let token = *b"tokentok";
        let start = Instant::now();
        let mut now = start;
        let mut a = Conn::new(token, now);
        let mut b = Conn::new(token, now);
        let data = sample(2_000_000);
        // 2 packets per ms (about 19 Mbit/s), 40 packets of queue, 15 ms each way.
        let mut queue: VecDeque<Vec<u8>> = VecDeque::new();
        let mut flight: VecDeque<(Instant, Vec<u8>)> = VecDeque::new();
        let mut back: VecDeque<(Instant, Vec<u8>)> = VecDeque::new();
        let delay = Duration::from_millis(15);
        let (mut sent, mut got) = (0, Vec::new());
        let step = Duration::from_millis(1);
        while got.len() < data.len() && now - start < Duration::from_secs(60) {
            if sent < data.len() {
                sent += a.write(&data[sent..]);
            }
            while let Some(p) = a.poll_transmit(now) {
                if queue.len() < 40 {
                    queue.push_back(p);
                }
            }
            for _ in 0..2 {
                if let Some(p) = queue.pop_front() {
                    flight.push_back((now + delay, p));
                }
            }
            while flight.front().is_some_and(|(t, _)| *t <= now) {
                b.on_packet(&flight.pop_front().unwrap().1, now);
            }
            got.extend(b.read(usize::MAX));
            while let Some(p) = b.poll_transmit(now) {
                back.push_back((now + delay, p));
            }
            while back.front().is_some_and(|(t, _)| *t <= now) {
                a.on_packet(&back.pop_front().unwrap().1, now);
            }
            a.on_timeout(now);
            b.on_timeout(now);
            now += step;
        }
        assert!(got == data);
        let took = (now - start).as_secs_f64();
        // The link's best is 1 s; under 2.5 means losses are repaired quickly.
        assert!(took < 2.5, "took {took} s");
    }

    #[test]
    fn a_quiet_peer_fails_the_stream() {
        let now = Instant::now();
        let mut a = Conn::new([1; 8], now);
        a.write(b"hello");
        let later = now + IDLE_TIMEOUT + Duration::from_secs(1);
        a.on_timeout(later);
        assert_eq!(a.state(), State::Failed);
    }

    #[test]
    fn foreign_and_short_packets_are_ignored() {
        let now = Instant::now();
        let mut a = Conn::new([1; 8], now);
        assert!(!a.on_packet(&[3, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 9], now));
        assert!(!a.on_packet(&[3, 1], now));
        let mut p = header(DATA, &[1; 8]);
        p.extend_from_slice(&0u32.to_be_bytes());
        assert!(!a.on_packet(&p, now), "empty DATA");
        p.extend_from_slice(b"hi");
        assert!(a.on_packet(&p, now));
        assert_eq!(a.read(100), b"hi");
        let reset = header(RESET, &[1; 8]);
        a.on_packet(&reset, now);
        assert_eq!(a.state(), State::Failed);
    }
}
