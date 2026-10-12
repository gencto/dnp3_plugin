//! Forward `tracing` output of the library to a Dart port.

use std::io::Write;
use std::sync::atomic::{AtomicI64, AtomicU8, Ordering};
use std::sync::Once;

use tracing::{Level, Metadata};
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::layer::SubscriberExt;

use crate::core::msg;
use crate::dart::{post, Payload};

static PORT: AtomicI64 = AtomicI64::new(0);
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
        let port = PORT.load(Ordering::Relaxed);
        if port != 0 {
            let text = String::from_utf8_lossy(&self.buf).trim_end().to_string();
            post(port, msg::LOG, self.level as i64, 0, Payload::Str(text));
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
