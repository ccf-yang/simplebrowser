//! Native transport.
//!
//! The only component allowed to open sockets. It builds a `wreq` client per
//! `(profile, proxy)` pair, sends headers in the profile-compatible order
//! (wreq's `OrigHeaderMap`), and supports cancellation through a shared token
//! registry.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use flutter_rust_bridge::for_generated::futures::StreamExt;
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;
use wreq::header::{HeaderMap, HeaderName, HeaderValue, OrigHeaderMap};
use wreq::{Client, Method, Proxy, redirect};

use crate::frb_generated::StreamSink;

use super::profile::{self, HeaderPair};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransportRequest {
    /// Correlates the request with `cancel` and with Dart-side logs.
    pub id: String,
    pub method: String,
    pub url: String,
    pub profile_id: String,
    /// Order is significant.
    pub headers: Vec<HeaderPair>,
    pub body: Option<Vec<u8>>,
    pub proxy_url: Option<String>,
    pub timeout_ms: Option<u64>,
    pub follow_redirects: bool,
    pub max_redirects: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransportResponse {
    pub status: u16,
    pub headers: Vec<HeaderPair>,
    pub body: Vec<u8>,
}

type ClientCache = Mutex<HashMap<String, Client>>;
type CancelRegistry = Mutex<HashMap<String, CancellationToken>>;

fn clients() -> &'static ClientCache {
    static CACHE: OnceLock<ClientCache> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn cancellations() -> &'static CancelRegistry {
    static REGISTRY: OnceLock<CancelRegistry> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// A poisoned lock still contains valid data; recover instead of panicking.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn client_for(profile_id: &str, proxy_url: Option<&str>) -> Result<Client, String> {
    let key = format!("{profile_id}|{}", proxy_url.unwrap_or_default());
    if let Some(client) = lock(clients()).get(&key) {
        return Ok(client.clone());
    }

    let mut builder = Client::builder()
        .emulation(profile::emulation(profile_id)?)
        .redirect(redirect::Policy::limited(10))
        .timeout(Duration::from_secs(60));

    if let Some(url) = proxy_url {
        let proxy =
            Proxy::all(url).map_err(|error| format!("transport.proxy:{error}"))?;
        builder = builder.proxy(proxy);
    }

    let client = builder
        .build()
        .map_err(|error| format!("transport.connect:{error}"))?;

    lock(clients()).insert(key, client.clone());
    Ok(client)
}

fn build_headers(
    headers: &[HeaderPair],
) -> Result<(HeaderMap, OrigHeaderMap), String> {
    let mut map = HeaderMap::new();
    let mut ordered = OrigHeaderMap::new();

    for header in headers {
        let name = HeaderName::from_bytes(header.name.as_bytes())
            .map_err(|error| format!("transport.protocol:invalid header name: {error}"))?;
        let value = HeaderValue::from_str(&header.value)
            .map_err(|error| format!("transport.protocol:invalid header value: {error}"))?;
        map.append(name.clone(), value);
        // Insert the original string (not `HeaderName`) so the case survives:
        // `HeaderName` normalizes to lowercase internally.
        ordered.insert(header.name.clone());
    }

    Ok((map, ordered))
}

fn map_error(error: wreq::Error) -> String {
    let code = if error.is_timeout() {
        "transport.timeout"
    } else if error.is_connect() {
        "transport.connect"
    } else if error.is_redirect() {
        "transport.protocol"
    } else {
        "transport.protocol"
    };
    format!("{code}:{error}")
}

/// Sends one request and buffers the whole response.
pub async fn send(req: TransportRequest) -> Result<TransportResponse, String> {
    let client = client_for(&req.profile_id, req.proxy_url.as_deref())?;

    let method = Method::from_bytes(req.method.as_bytes())
        .map_err(|error| format!("transport.protocol:invalid method: {error}"))?;

    let mut builder = client.request(method, req.url.as_str());

    if !req.headers.is_empty() {
        let (map, ordered) = build_headers(&req.headers)?;
        builder = builder.headers(map).orig_headers(ordered);
    }

    if let Some(body) = req.body {
        builder = builder.body(body);
    }

    if !req.follow_redirects {
        builder = builder.redirect(redirect::Policy::none());
    } else if req.max_redirects > 0 {
        builder = builder.redirect(redirect::Policy::limited(req.max_redirects as usize));
    }

    if let Some(timeout_ms) = req.timeout_ms {
        builder = builder.timeout(Duration::from_millis(timeout_ms));
    }

    let token = CancellationToken::new();
    lock(cancellations()).insert(req.id.clone(), token.clone());

    let outcome = tokio::select! {
        _ = token.cancelled() => Err("cancelled:request cancelled".to_string()),
        result = builder.send() => result.map_err(map_error),
    };

    lock(cancellations()).remove(&req.id);

    let response = outcome?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| HeaderPair {
            name: name.to_string(),
            value: value.to_str().unwrap_or_default().to_string(),
        })
        .collect();
    let body = response
        .bytes()
        .await
        .map_err(map_error)?
        .to_vec();

    Ok(TransportResponse {
        status,
        headers,
        body,
    })
}

/// Events emitted by [`open_stream`].
///
/// Headers arrive before any body byte, so Dart can decide whether the
/// response is an SSE stream, an error page, or a redirect.
///
/// A flat struct is used instead of an enum with data: flutter_rust_bridge
/// would generate a `freezed` class for a complex enum, and this package
/// deliberately keeps zero Dart codegen dependencies.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamEvent {
    /// `head`, `data` or `end`.
    pub kind: String,
    pub status: Option<u16>,
    pub headers: Vec<HeaderPair>,
    pub bytes: Vec<u8>,
}

impl StreamEvent {
    fn head(status: u16, headers: Vec<HeaderPair>) -> Self {
        Self {
            kind: "head".to_string(),
            status: Some(status),
            headers,
            bytes: Vec::new(),
        }
    }

    fn data(bytes: Vec<u8>) -> Self {
        Self {
            kind: "data".to_string(),
            status: None,
            headers: Vec::new(),
            bytes,
        }
    }

    fn end() -> Self {
        Self {
            kind: "end".to_string(),
            status: None,
            headers: Vec::new(),
            bytes: Vec::new(),
        }
    }
}

/// Sends a request and forwards the body as it arrives.
///
/// The response is not buffered in Rust; this is what makes SSE and long-lived
/// downloads work without holding the whole body in memory.
pub async fn open_stream(
    req: TransportRequest,
    sink: StreamSink<StreamEvent>,
) -> Result<(), String> {
    let client = client_for(&req.profile_id, req.proxy_url.as_deref())?;

    let method = Method::from_bytes(req.method.as_bytes())
        .map_err(|error| format!("transport.protocol:invalid method: {error}"))?;

    let mut builder = client.request(method, req.url.as_str());

    if !req.headers.is_empty() {
        let (map, ordered) = build_headers(&req.headers)?;
        builder = builder.headers(map).orig_headers(ordered);
    }

    if let Some(body) = req.body {
        builder = builder.body(body);
    }

    if !req.follow_redirects {
        builder = builder.redirect(redirect::Policy::none());
    } else if req.max_redirects > 0 {
        builder = builder.redirect(redirect::Policy::limited(req.max_redirects as usize));
    }

    if let Some(timeout_ms) = req.timeout_ms {
        builder = builder.timeout(Duration::from_millis(timeout_ms));
    }

    let token = CancellationToken::new();
    lock(cancellations()).insert(req.id.clone(), token.clone());

    let response = tokio::select! {
        _ = token.cancelled() => {
            lock(cancellations()).remove(&req.id);
            return Err("cancelled:request cancelled".to_string());
        }
        result = builder.send() => result.map_err(map_error)?,
    };

    let head = StreamEvent::head(
        response.status().as_u16(),
        response
            .headers()
            .iter()
            .map(|(name, value)| HeaderPair {
                name: name.to_string(),
                value: value.to_str().unwrap_or_default().to_string(),
            })
            .collect(),
    );
    sink.add(head).map_err(|error| format!("transport.protocol:{error}"))?;

    let mut body = response.bytes_stream();
    loop {
        let next = tokio::select! {
            _ = token.cancelled() => {
                lock(cancellations()).remove(&req.id);
                return Err("cancelled:request cancelled".to_string());
            }
            item = body.next() => item,
        };
        match next {
            Some(Ok(chunk)) => {
                if !chunk.is_empty() {
                    sink.add(StreamEvent::data(chunk.to_vec()))
                        .map_err(|error| format!("transport.protocol:{error}"))?;
                }
            }
            Some(Err(error)) => {
                lock(cancellations()).remove(&req.id);
                return Err(map_error(error));
            }
            None => break,
        }
    }

    lock(cancellations()).remove(&req.id);
    sink.add(StreamEvent::end())
        .map_err(|error| format!("transport.protocol:{error}"))?;
    Ok(())
}

/// Aborts an in-flight request. Safe to call for unknown ids.
pub fn cancel(request_id: String) {
    if let Some(token) = lock(cancellations()).remove(&request_id) {
        token.cancel();
    }
}

/// Drops all cached clients. Called when a session closes.
pub fn clear_clients() {
    lock(clients()).clear();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_header_name_is_rejected() {
        let error = build_headers(&[HeaderPair {
            name: "bad header".to_string(),
            value: "x".to_string(),
        }])
        .unwrap_err();
        assert!(error.starts_with("transport.protocol:"));
    }

    #[test]
    fn duplicate_headers_are_preserved() {
        let (map, _ordered) = build_headers(&[
            HeaderPair {
                name: "accept".to_string(),
                value: "text/html".to_string(),
            },
            HeaderPair {
                name: "accept".to_string(),
                value: "application/json".to_string(),
            },
        ])
        .unwrap();
        assert_eq!(map.get_all("accept").iter().count(), 2);
    }
}
