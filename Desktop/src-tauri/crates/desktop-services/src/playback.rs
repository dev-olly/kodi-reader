//! Playback ownership shared by queued requests, preparation workers and Stop.
use crate::CancellationToken;

#[derive(Clone, Debug)]
pub struct PlaybackRequest {
    id: u64,
    cancel: CancellationToken,
}
impl PlaybackRequest {
    pub fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }
    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }
}

/// Mutate only while the hub's playback mutex is held. In particular the
/// prepared stream is started and installed inside the same ownership lock.
pub(crate) struct PlaybackOwner<T> {
    next: u64,
    current: Option<PlaybackRequest>,
    pub playback: Option<T>,
}
impl<T> Default for PlaybackOwner<T> {
    fn default() -> Self {
        Self {
            next: 0,
            current: None,
            playback: None,
        }
    }
}
impl<T> PlaybackOwner<T> {
    pub fn request(&mut self) -> (PlaybackRequest, Option<T>) {
        if let Some(old) = self.current.take() {
            old.cancel.cancel();
        }
        self.next = self
            .next
            .checked_add(1)
            .expect("Playback generation exhausted");
        let request = PlaybackRequest {
            id: self.next,
            cancel: CancellationToken::new(),
        };
        self.current = Some(request.clone());
        (request, self.playback.take())
    }
    pub fn is_current(&self, request: &PlaybackRequest) -> bool {
        !request.cancel.is_cancelled()
            && self
                .current
                .as_ref()
                .is_some_and(|current| current.id == request.id)
    }
    pub fn cancel(&mut self) -> Option<T> {
        if let Some(request) = self.current.take() {
            request.cancel.cancel();
        }
        self.playback.take()
    }
    pub fn finish(&mut self, request: &PlaybackRequest) -> Option<T> {
        if self.is_current(request) {
            self.playback.take()
        } else {
            None
        }
    }
    pub fn install(
        &mut self,
        request: &PlaybackRequest,
        playback: T,
    ) -> std::result::Result<Option<T>, T> {
        if !self.is_current(request) {
            return Err(playback);
        }
        Ok(self.playback.replace(playback))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn queued_preparation_cannot_install_after_stop() {
        let mut owner = PlaybackOwner::default();
        let (request, _) = owner.request();
        owner.cancel();
        assert!(request.is_cancelled());
        assert_eq!(owner.install(&request, "prepared"), Err("prepared"));
        assert!(owner.playback.is_none());
    }
    #[test]
    fn latest_request_wins_even_when_older_preparation_finishes_last() {
        let mut owner = PlaybackOwner::default();
        let (old, _) = owner.request();
        let (new, _) = owner.request();
        assert_eq!(owner.install(&new, "new"), Ok(None));
        assert_eq!(owner.install(&old, "old"), Err("old"));
        assert_eq!(owner.finish(&old), None);
        assert_eq!(owner.playback, Some("new"));
    }
    #[test]
    fn narration_can_finish_one_passage_without_invalidating_its_run() {
        let mut owner = PlaybackOwner::default();
        let (run, _) = owner.request();
        assert_eq!(owner.install(&run, "first"), Ok(None));
        assert_eq!(owner.finish(&run), Some("first"));
        assert!(!run.is_cancelled());
        assert_eq!(owner.install(&run, "next"), Ok(None));
        assert_eq!(owner.cancel(), Some("next"));
        assert!(run.is_cancelled());
    }
}
