use crate::{checked, http_client, CancellationToken, PublicConfig};
use anyhow::{bail, Context, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatRequest {
    pub request_id: uuid::Uuid,
    pub messages: Vec<Message>,
}
pub struct AiService {
    config: PublicConfig,
    client: reqwest::Client,
}
impl AiService {
    pub fn new(config: PublicConfig) -> Result<Self> {
        config.validate()?;
        Ok(Self {
            config,
            client: http_client()?,
        })
    }
    pub async fn stream(
        &self,
        request: ChatRequest,
        token: &str,
        cancel: CancellationToken,
        mut on_delta: impl FnMut(String) + Send,
    ) -> Result<()> {
        let send = self
            .client
            .post(format!(
                "{}/chat/completions",
                self.config.ai_base_url.trim_end_matches('/')
            ))
            .bearer_auth(token)
            .header("Accept", "text/event-stream")
            .header("Idempotency-Key", request.request_id.to_string())
            .header("X-Kodi-Credit-Protocol", "1")
            .header("X-Title", "Kodi Reader")
            .header("HTTP-Referer", "https://github.com/dev-olly/kodi-reader")
            .json(&json!({"model":self.config.ai_model,"stream":true,"messages":request.messages}))
            .send();
        let response =
            tokio::select! { _ = cancel.cancelled() => bail!("Request cancelled"), r = send => r? };
        match response.status().as_u16() {
            401 => bail!("Please sign in again to use Ask AI"),
            402 => bail!(if self.config.payments_enabled {
                "You have no credits left"
            } else {
                "Ask AI is temporarily unavailable"
            }),
            _ => {}
        }
        let mut bytes = checked(response).await?.bytes_stream();
        let mut parser = SseParser::default();
        let mut received = false;
        loop {
            let chunk = tokio::select! { _=cancel.cancelled()=>bail!("Request cancelled"), r=bytes.next()=>r };
            let Some(chunk) = chunk else {
                bail!("The reply was interrupted. Please try again");
            };
            for payload in parser.push(&chunk?)? {
                if payload == "[DONE]" {
                    if !received {
                        bail!("The model returned an empty reply");
                    }
                    return Ok(());
                }
                let value: Value = serde_json::from_str(&payload).context("Invalid AI event")?;
                if !value["error"].is_null() {
                    bail!("Ask AI returned a model error");
                }
                if let Some(delta) = value["choices"][0]["delta"]["content"]
                    .as_str()
                    .or_else(|| value["choices"][0]["delta"]["text"].as_str())
                    .or_else(|| value["choices"][0]["text"].as_str())
                {
                    if !delta.is_empty() {
                        received = true;
                        on_delta(delta.to_owned());
                    }
                }
            }
        }
    }
    pub async fn credits(&self, token: &str) -> Result<Value> {
        if !self.config.payments_enabled {
            return Ok(json!({"balance":null,"enforced":false}));
        }
        self.get("credits", token).await
    }
    pub async fn credit_packs(&self, token: &str) -> Result<Value> {
        if !self.config.payments_enabled {
            return Ok(json!({"packs":[],"sandbox":false}));
        }
        self.get("credit-packs", token).await
    }
    async fn get(&self, path: &str, token: &str) -> Result<Value> {
        Ok(checked(
            self.client
                .get(format!(
                    "{}/{path}",
                    self.config.ai_base_url.trim_end_matches('/')
                ))
                .bearer_auth(token)
                .send()
                .await?,
        )
        .await?
        .json()
        .await?)
    }
    pub async fn checkout(&self, token: &str, pack: &str, id: uuid::Uuid) -> Result<String> {
        if !self.config.payments_enabled {
            bail!("Payments are disabled in this build");
        }
        let result: Value = checked(
            self.client
                .post(format!(
                    "{}/checkout",
                    self.config.ai_base_url.trim_end_matches('/')
                ))
                .bearer_auth(token)
                .header("Idempotency-Key", id.to_string())
                .json(&json!({"pack":pack}))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        let url = result["url"].as_str().context("Missing checkout URL")?;
        crate::require_https(url)?;
        Ok(url.into())
    }
    pub async fn purchase(&self, token: &str, id: uuid::Uuid) -> Result<Value> {
        self.get(&format!("checkout/{id}"), token).await
    }
}
/// Parses UTF-8 only after full lines arrive, including split multibyte characters.
#[derive(Default)]
pub struct SseParser {
    buffer: Vec<u8>,
    data: Vec<String>,
}
impl SseParser {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<String>> {
        self.buffer.extend_from_slice(bytes);
        if self.buffer.len() > 1024 * 1024 {
            bail!("AI event exceeds the allowed size");
        }
        let mut output = Vec::new();
        while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
            let bytes: Vec<u8> = self.buffer.drain(..=end).collect();
            let line = std::str::from_utf8(&bytes)?.trim_end_matches(['\r', '\n']);
            if line.is_empty() {
                if !self.data.is_empty() {
                    output.push(self.data.join("\n"));
                    self.data.clear();
                }
            } else if let Some(data) = line.strip_prefix("data:") {
                self.data
                    .push(data.strip_prefix(' ').unwrap_or(data).into());
            }
        }
        Ok(output)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_split_utf8_and_multiline_events() {
        let mut p = SseParser::default();
        let event = "data: hé\ndata: next\n\ndata: [DONE]\n\n".as_bytes();
        let mut out = vec![];
        for b in event {
            out.extend(p.push(&[*b]).unwrap());
        }
        assert_eq!(out, vec!["hé\nnext", "[DONE]"]);
    }
    #[test]
    fn ignores_comments_and_event_ids() {
        assert_eq!(
            SseParser::default()
                .push(b":ping\nid: 2\ndata: yes\r\n\r\n")
                .unwrap(),
            vec!["yes"]
        );
    }
}
