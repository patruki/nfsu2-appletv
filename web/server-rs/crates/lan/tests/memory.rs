//! What the switch keeps of a burst once it is over (a test binary of its own: its allocator counts the bytes live,
//! and nothing else runs in it at the same time).

mod harness;

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicIsize, Ordering::Relaxed};

use harness::*;
use nfsu2_lan::LanOptions;
use tokio::io::AsyncReadExt;

/// the system's allocator, counting the bytes it holds for the process
struct Counting;

static LIVE: AtomicIsize = AtomicIsize::new(0);

// SAFETY: every call goes to the system's allocator as it came; the count is all that is added
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        LIVE.fetch_add(l.size() as isize, Relaxed);
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size() as isize, Relaxed);
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        LIVE.fetch_add(l.size() as isize, Relaxed);
        unsafe { System.alloc_zeroed(l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        LIVE.fetch_add(n as isize - l.size() as isize, Relaxed);
        unsafe { System.realloc(p, l, n) }
    }
}

#[global_allocator]
static A: Counting = Counting;

fn live() -> isize {
    LIVE.load(Relaxed)
}

/// A receiver whose link stalls (a tunnel's hiccup: every player's at once) gets what waited in one write when the
/// link comes back.  That write's buffers are let go once it went: kept, they were a burst's worth for every
/// connection for good (at 2000 players the hello's peer list alone, about 100 KB, made it 256 MB).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_bursts_buffers_are_not_kept_once_it_went() {
    let sw = start(LanOptions {
        frame_rate: 100000.0,
        byte_rate: (64 << 20) as f64,
        group_frame_rate: 100000.0,
        group_byte_rate: (64 << 20) as f64,
        send_buffer_os: 8 << 10,
        ..opts()
    })
    .await;
    // reads nothing until told to: its link stalls
    let mut receiver = raw_peer_with(sw.port, "Receiver", "?g=r", Some(8 << 10)).await;
    let mut sender = Client::with(sw.port, "Sender", "?g=s", Opts::default()).await;
    sender.welcome().await;
    sleep(200).await;
    let pv = sw.peer_named("Receiver").unwrap();
    let mut buf = vec![0u8; 64 << 10];
    let before = live();
    // a queue of shedQueue's worth (256 KB) of LAN play's datagrams, in frames of about 100 bytes, once the kernel's
    // buffers are full: 3000 of them with the small buffers asked for above.  macOS gives a loopback connection far
    // more room than SO_SNDBUF and SO_RCVBUF ask (it took all 3000, 300 KB, and the switch queued nothing), so there
    // more go until the switch queues (8 MB at most)
    let buffered = || sw.peers().iter().find(|p| p.vip == pv.vip).map_or(0, |p| p.buffered);
    let mut sent = 0;
    while sent < 3000 || (buffered() <= 128 << 10 && sent < 80_000) {
        for _ in 0..500 {
            sender.udp(pv.vip, 1, 2, &[7; 84], 3, 0);
        }
        sent += 500;
        sender.flush().await;
        sleep(5).await;
    }
    sleep(300).await;
    let queued = buffered();
    // the link is back: all of it goes, then nothing more comes
    let mut got = 0;
    loop {
        match tokio::time::timeout(std::time::Duration::from_millis(300), receiver.read(&mut buf)).await {
            Ok(Ok(n)) if n > 0 => got += n,
            _ => break,
        }
    }
    sleep(100).await;
    let kept = live() - before;
    println!("{sent} datagrams; queued {queued} bytes, the receiver read {got}; heap after the burst: {kept} bytes more than before");
    assert!(queued > 128 << 10, "the receiver's queue filled ({queued})");
    assert!(got > queued, "the receiver got it all ({got})");
    assert!(kept < 96 << 10, "the burst's buffers went with it ({kept} bytes kept)");
    sender.close().await;
    drop(receiver);
    sw.close().await;
}
