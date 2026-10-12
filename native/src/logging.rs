//! Forward `tracing` output of the library to a Dart port.

use std::io::Write;
use std::sync::atomic::{AtomicI64, AtomicU8, Ordering};
use std::sync::{Mutex, Once};

use tracing::{Level, Metadata};
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::layer::SubscriberExt;

use crate::core::msg;
use crate::dart::{post, Payload};

static PORT: AtomicI64 = AtomicI64::new(0);

/// Log records are handed to a dedicated thread which posts them to Dart. This keeps
/// `Dart_PostCObject` out of every FFI call (some of which are `isLeaf` calls) and keeps
/// formatting/posting off the protocol threads.
static SENDER: std::sync::OnceLock<Mutex<std::sync::mpsc::Sender<(u8, String)>>> = std::sync::OnceLock::new();

fn sender() -> &'static Mutex<std::sync::mpsc::Sender<(u8, String)>> {
    SENDER.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::channel::<(u8, String)>();
        std::thread::Builder::new()
            .name("dnp3-log".to_string())
            .spawn(move || {
                for (level, text) in rx {
                    let port = PORT.load(Ordering::Relaxed);
                    if port != 0 {
                        post(port, msg::LOG, level as i64, 0, Payload::Str(text));
                    }
                }
            })
            .expect("unable to spawn log thread");
        Mutex::new(tx)
    })
}
/// 0 off, 1 error, 2 warn, 3 info, 4 debug, 5 trace
static LEVEL: AtomicU8 = AtomicU8::new(3);
static INIT: Once = Once::new();

fn level_code(l: &Level) -> u8 {
    match *l {
        Level::ERROR => 1,
        Level::WARN => 2,
        Level::INFO => 3,
        Level::DEBUG => 4,
        Level::TRACE => 5,
    }
}

fn enabled(meta: &Metadata) -> bool {
    level_code(meta.level()) <= LEVEL.load(Ordering::Relaxed) && PORT.load(Ordering::Relaxed) != 0
}

pub struct DartWriter {
    level: u8,
    buf: Vec<u8>,
}

impl Write for DartWriter {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for DartWriter {
    fn drop(&mut self) {
        if self.buf.is_empty() {
            return;
        }
        if PORT.load(Ordering::Relaxed) != 0 {
            let text = String::from_utf8_lossy(&self.buf).trim_end().to_string();
            if let Ok(tx) = sender().lock() {
                let _ = tx.send((self.level, text));
            }
        }
    }
}

struct DartMakeWriter;

impl<'a> MakeWriter<'a> for DartMakeWriter {
    type Writer = DartWriter;

    fn make_writer(&'a self) -> Self::Writer {
        DartWriter {
            level: 3,
            buf: Vec::with_capacity(128),
        }
    }

    fn make_writer_for(&'a self, meta: &Metadata<'_>) -> Self::Writer {
        DartWriter {
            level: level_code(meta.level()),
            buf: Vec::with_capacity(128),
        }
    }
}

/// Install the subscriber (once) and set the destination port and level
pub fn init(port: i64, level: u8, with_target: bool) -> bool {
    PORT.store(port, Ordering::Relaxed);
    LEVEL.store(level, Ordering::Relaxed);
    let mut installed = false;
    INIT.call_once(|| {
        let layer = tracing_subscriber::fmt::layer()
            .with_writer(DartMakeWriter)
            .with_ansi(false)
            .with_level(false)
            .with_target(with_target)
            .without_time();
        let filter = tracing_subscriber::filter::dynamic_filter_fn(|meta, _cx| enabled(meta));
        let subscriber = tracing_subscriber::registry().with(
            tracing_subscriber::Layer::with_filter(layer, filter),
        );
        installed = tracing::subscriber::set_global_default(subscriber).is_ok();
    });
    tracing::callsite::rebuild_interest_cache();
    installed
}

pub fn set_level(level: u8) {
    LEVEL.store(level, Ordering::Relaxed);
    tracing::callsite::rebuild_interest_cache();
}
