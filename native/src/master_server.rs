//! A master acting as a TCP server that accepts connections from outstations
//! (`dnp3::tcp::spawn_master_tcp_server`). Accept decisions are delegated to Dart
//! asynchronously.

use std::future::Future;
use std::net::SocketAddr;
use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use dnp3::master::MasterChannel;
use dnp3::tcp::{AcceptAction, AcceptConfig, ConnectionHandler, LinkIdConfig, Reject, ServerHandle};

use crate::codec::Writer;
use crate::config::{self, AcceptActionDto, AcceptConfigDto, MasterServerDto};
use crate::core::*;
use crate::dart::DartPort;

pub struct MasterServerEntry {
    _handle: ServerHandle,
    channels: Arc<Mutex<Vec<u64>>>,
}

static SERVERS: Registry<Arc<MasterServerEntry>> = Registry::new();

pub fn clear() {
    SERVERS.clear();
}

pub mod request {
    pub const ACCEPT: u8 = 0;
    pub const START: u8 = 1;
    pub const ACCEPT_LINK_ID: u8 = 2;
    pub const START_WITH_LINK_ID: u8 = 3;
}

/// `u8 type, u8 pad, u16 source, u16 destination, u16 pad, u64 channel, blob address`
fn encode(kind: u8, source: u16, destination: u16, channel: u64, addr: SocketAddr) -> Vec<u8> {
    let mut w = Writer::with_capacity(48);
    w.u8(kind);
    w.u8(0);
    w.u16(source);
    w.u16(destination);
    w.u16(0);
    w.u64(channel);
    w.blob(addr.to_string().as_bytes());
    w.finish()
}

fn accept_config(dto: AcceptConfigDto) -> Option<AcceptConfig> {
    match dto.channel.to_config() {
        Ok(config) => Some(AcceptConfig {
            error_mode: dto.link_error_mode.into(),
            config,
        }),
        Err(e) => {
            tracing::warn!("invalid accept configuration from Dart: {}", e.message);
            None
        }
    }
}

struct Handler {
    id: i64,
    port: DartPort,
    timeout: Duration,
    channels: Arc<Mutex<Vec<u64>>>,
}

impl Handler {
    fn register(&self, channel: MasterChannel) -> u64 {
        let id = next_id();
        crate::master::register_channel(id, channel);
        self.channels.lock().unwrap().push(id);
        id
    }
}

impl ConnectionHandler for Handler {
    fn accept(&mut self, addr: SocketAddr) -> impl Future<Output = std::result::Result<AcceptAction, Reject>> + Send {
        let (port, id, timeout) = (self.port, self.id, self.timeout);
        async move {
            let reply = request_async(
                port,
                msg::MASTER_SERVER_REQUEST,
                id,
                encode(request::ACCEPT, 0, 0, 0, addr),
                timeout,
            )
            .await
            .ok_or(Reject)?;
            if reply.status == 0 {
                return Err(Reject);
            }
            let text = std::str::from_utf8(&reply.data).map_err(|_| Reject)?;
            match config::parse::<AcceptActionDto>(text) {
                Ok(AcceptActionDto::Reject) => Err(Reject),
                Ok(AcceptActionDto::GetLinkIdentity) => Ok(AcceptAction::GetLinkIdentity),
                Ok(AcceptActionDto::Accept { config }) => {
                    accept_config(config).map(AcceptAction::Accept).ok_or(Reject)
                }
                Err(e) => {
                    tracing::warn!("invalid accept action from Dart: {}", e.message);
                    Err(Reject)
                }
            }
        }
    }

    fn start(&mut self, channel: MasterChannel, addr: SocketAddr) -> impl Future<Output = ()> + Send {
        let channel_id = self.register(channel);
        let (port, id, timeout) = (self.port, self.id, self.timeout);
        async move {
            // wait until Dart has configured the channel (associations, enable)
            let _ = request_async(
                port,
                msg::MASTER_SERVER_REQUEST,
                id,
                encode(request::START, 0, 0, channel_id, addr),
                timeout,
            )
            .await;
        }
    }

    fn accept_link_id(
        &mut self,
        addr: SocketAddr,
        source: u16,
        destination: u16,
    ) -> impl Future<Output = std::result::Result<AcceptConfig, Reject>> + Send {
        let (port, id, timeout) = (self.port, self.id, self.timeout);
        async move {
            let reply = request_async(
                port,
                msg::MASTER_SERVER_REQUEST,
                id,
                encode(request::ACCEPT_LINK_ID, source, destination, 0, addr),
                timeout,
            )
            .await
            .ok_or(Reject)?;
            if reply.status == 0 {
                return Err(Reject);
            }
            let text = std::str::from_utf8(&reply.data).map_err(|_| Reject)?;
            let dto: AcceptConfigDto = config::parse(text).map_err(|_| Reject)?;
            accept_config(dto).ok_or(Reject)
        }
    }

    fn start_with_link_id(
        &mut self,
        channel: MasterChannel,
        addr: SocketAddr,
        source: u16,
        destination: u16,
    ) -> impl Future<Output = ()> + Send {
        let channel_id = self.register(channel);
        let (port, id, timeout) = (self.port, self.id, self.timeout);
        async move {
            let _ = request_async(
                port,
                msg::MASTER_SERVER_REQUEST,
                id,
                encode(request::START_WITH_LINK_ID, source, destination, channel_id, addr),
                timeout,
            )
            .await;
        }
    }
}

/// Create and bind the server. Completes with `"<server id>|<local address>"`.
pub fn create(json: &str, events: DartPort, c: Completion) -> Result<i64> {
    let dto: MasterServerDto = config::parse(json)?;
    let local = config::socket_addr(&dto.address)?;
    let max_tasks = NonZeroUsize::new(dto.link_id_config.max_tasks)
        .ok_or_else(|| Error::config("maxTasks must be > 0"))?;
    let link_id = LinkIdConfig::new()
        .max_tasks(max_tasks)
        .timeout(config::timeout_ms(dto.link_id_config.timeout_ms)?)
        .decode_level(dto.link_id_config.decode_level.into());
    let id = next_id();
    let channels = Arc::new(Mutex::new(Vec::new()));
    let handler = Handler {
        id: id as i64,
        port: events,
        timeout: Duration::from_millis(dto.callback_timeout_ms),
        channels: channels.clone(),
    };
    spawn_op(c, async move {
        let handle = dnp3::tcp::spawn_master_tcp_server(local, link_id, handler).await?;
        let addr = handle.local_addr().map(|x| x.to_string()).unwrap_or_default();
        SERVERS.insert_with_id(
            id,
            Arc::new(MasterServerEntry {
                _handle: handle,
                channels,
            }),
        );
        Ok(format!("{id}|{addr}"))
    })
}

pub fn destroy(id: u64) -> Result<i64> {
    let entry = SERVERS.remove(id).ok_or_else(|| Error::invalid_handle(id))?;
    let channels = std::mem::take(&mut *entry.channels.lock().unwrap());
    for ch in channels {
        let _ = crate::master::destroy(ch);
    }
    Ok(0)
}
