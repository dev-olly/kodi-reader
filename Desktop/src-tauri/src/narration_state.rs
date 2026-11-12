use serde_json::Value;

#[derive(Clone, Debug)]
pub(crate) struct NarrationPlan {
    pub passages: Vec<Value>,
    pub durations: Vec<f64>,
    pub known_durations: Vec<bool>,
    pub index: usize,
    pub offset: f64,
    pub voice: String,
    pub rate: f32,
    pub paused: bool,
}

pub(crate) fn validate_options(voice: &str, rate: f32) -> crate::Result<()> {
    if !(0.5..=2.).contains(&rate) || !["anna", "azelma", "charles", "george"].contains(&voice) {
        return Err("Choose an available voice and playback speed.".into());
    }
    Ok(())
}

impl NarrationPlan {
    pub fn new(
        passages: Vec<Value>,
        voice: String,
        rate: f32,
        paused: bool,
    ) -> crate::Result<Self> {
        validate_options(&voice, rate)?;
        let passages: Vec<_> = passages
            .into_iter()
            .filter(|passage| {
                passage["text"]
                    .as_str()
                    .is_some_and(|text| !text.trim().is_empty())
            })
            .collect();
        let durations: Vec<_> = passages
            .iter()
            .map(|passage| {
                (passage["text"]
                    .as_str()
                    .unwrap_or("")
                    .split_whitespace()
                    .count() as f64
                    / 2.6)
                    .max(1.)
            })
            .collect();
        let known_durations = vec![false; passages.len()];
        Ok(Self {
            passages,
            durations,
            known_durations,
            index: 0,
            offset: 0.,
            voice,
            rate,
            paused,
        })
    }
    pub fn duration(&self) -> f64 {
        self.durations.iter().sum()
    }
    pub fn elapsed(&self, offset: f64) -> f64 {
        self.durations.iter().take(self.index).sum::<f64>()
            + offset
                .max(0.)
                .min(self.durations.get(self.index).copied().unwrap_or(0.))
    }
    pub fn set_duration(&mut self, index: usize, duration: f64) {
        if duration.is_finite() && duration > 0. {
            if let Some(value) = self.durations.get_mut(index) {
                *value = duration;
                self.known_durations[index] = true;
            }
        }
    }
    pub fn seek(&self, seconds: f64, paused: bool) -> crate::Result<Self> {
        if !seconds.is_finite() {
            return Err("Choose a valid narration position.".into());
        }
        if self.passages.is_empty() {
            return Err("There is no narration to seek.".into());
        }
        let target = seconds.clamp(0., (self.duration() - 0.01).max(0.));
        let mut index = 0;
        let mut start = 0.;
        while index + 1 < self.durations.len() && start + self.durations[index] <= target {
            start += self.durations[index];
            index += 1;
        }
        Ok(Self {
            index,
            offset: target - start,
            paused,
            ..self.clone()
        })
    }
    pub fn skip(&self, seconds: f64, source_offset: f64, paused: bool) -> crate::Result<Self> {
        self.seek(
            self.elapsed(source_offset) + seconds * self.rate as f64,
            paused,
        )
    }
    pub fn audio_state(&self, phase: &str, offset: f64) -> Value {
        serde_json::json!({"phase":phase,"kind":"narration","elapsed":self.elapsed(offset),"duration":self.duration(),"hasEstimatedDuration":self.known_durations.iter().any(|known| !known),"passageIndex":self.index,"voice":self.voice,"rate":self.rate,"title":"Listen"})
    }
    pub fn with_options(
        &self,
        voice: String,
        rate: f32,
        elapsed: Option<f64>,
        paused: bool,
    ) -> crate::Result<Self> {
        validate_options(&voice, rate)?;
        let offset = elapsed
            .filter(|value| value.is_finite() && *value >= 0.)
            .unwrap_or(self.offset);
        let mut next = Self {
            voice,
            rate,
            offset,
            paused,
            ..self.clone()
        };
        if next.voice != self.voice {
            next.durations = self
                .passages
                .iter()
                .map(|passage| {
                    (passage["text"]
                        .as_str()
                        .unwrap_or("")
                        .split_whitespace()
                        .count() as f64
                        / 2.6)
                        .max(1.)
                })
                .collect();
            next.known_durations.fill(false);
        }
        Ok(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn plan() -> NarrationPlan {
        NarrationPlan {
            passages: vec![
                json!({"text":"one"}),
                json!({"text":"two"}),
                json!({"text":"three"}),
            ],
            durations: vec![10., 20., 30.],
            known_durations: vec![true, true, false],
            index: 1,
            offset: 4.5,
            voice: "anna".into(),
            rate: 1.,
            paused: false,
        }
    }
    #[test]
    fn changing_speed_keeps_the_current_passage_and_source_time() {
        let next = plan()
            .with_options("anna".into(), 1.75, Some(8.25), false)
            .unwrap();
        assert_eq!(next.index, 1);
        assert_eq!(next.offset, 8.25);
        assert_eq!(next.passages[next.index]["text"], "two");
        assert_eq!(next.rate, 1.75);
    }
    #[test]
    fn changing_voice_while_paused_does_not_restart_the_chapter_or_resume_playback() {
        let next = plan()
            .with_options("george".into(), 1., Some(12.), true)
            .unwrap();
        assert_eq!(next.index, 1);
        assert_eq!(next.offset, 12.);
        assert_eq!(next.voice, "george");
        assert!(next.paused);
    }
    #[test]
    fn options_changed_during_preparation_retain_the_resume_offset() {
        for elapsed in [None, Some(f64::NAN), Some(-1.)] {
            assert_eq!(
                plan()
                    .with_options("charles".into(), 0.75, elapsed, true)
                    .unwrap()
                    .offset,
                4.5
            );
        }
    }
    #[test]
    fn invalid_narration_options_cannot_replace_an_active_run() {
        for rate in [f32::NAN, f32::INFINITY, 0., 2.01] {
            assert!(plan()
                .with_options("anna".into(), rate, Some(0.), false)
                .is_err());
        }
        assert!(plan()
            .with_options("unknown".into(), 1., Some(0.), false)
            .is_err());
    }
    #[test]
    fn chapter_seek_crosses_passages_and_preserves_pause() {
        let next = plan().seek(35., true).unwrap();
        assert_eq!(next.index, 2);
        assert_eq!(next.offset, 5.);
        assert!(next.paused);
        let previous = next.seek(8., true).unwrap();
        assert_eq!(previous.index, 0);
        assert_eq!(previous.offset, 8.);
        assert!(previous.paused);
    }
    #[test]
    fn skip_uses_playback_speed_and_crosses_both_passage_boundaries() {
        let mut current = plan();
        current.rate = 1.5;
        let next = current.skip(15., 5., true).unwrap();
        assert_eq!(next.index, 2);
        assert_eq!(next.offset, 7.5);
        assert!(next.paused);
        let previous = next.skip(-15., 7.5, true).unwrap();
        assert_eq!(previous.index, 1);
        assert_eq!(previous.offset, 5.);
        assert!(previous.paused);
    }
    #[test]
    fn elapsed_and_duration_include_known_and_estimated_passages() {
        let mut plan = plan();
        assert_eq!(plan.duration(), 60.);
        assert_eq!(plan.elapsed(4.5), 14.5);
        assert_eq!(
            plan.audio_state("playing", 4.5)["hasEstimatedDuration"],
            true
        );
        plan.set_duration(2, 12.);
        assert_eq!(plan.duration(), 42.);
        assert_eq!(
            plan.audio_state("paused", 4.5)["hasEstimatedDuration"],
            false
        );
        assert_eq!(plan.seek(31., false).unwrap().offset, 1.);
    }
    #[test]
    fn seek_clamps_edges_and_rejects_invalid_time_without_moving() {
        assert_eq!(plan().seek(-2., false).unwrap().offset, 0.);
        let last = plan().seek(200., false).unwrap();
        assert_eq!(last.index, 2);
        assert!((last.offset - 29.99).abs() < 0.0001);
        assert!(plan().seek(f64::NAN, false).is_err());
    }
    #[test]
    fn new_chapters_estimate_like_mac_and_voice_changes_invalidate_known_durations() {
        let plan = NarrationPlan::new(vec![json!({"text":"one two three four five six seven eight nine ten eleven twelve thirteen"}), json!({"text":"tiny"})], "anna".into(), 1., false).unwrap();
        assert_eq!(plan.durations, vec![5., 1.]);
        let mut known = plan.clone();
        known.set_duration(0, 4.);
        assert_eq!(
            known
                .with_options("anna".into(), 1.5, None, false)
                .unwrap()
                .durations,
            vec![4., 1.]
        );
        let changed = known
            .with_options("george".into(), 1.5, None, true)
            .unwrap();
        assert_eq!(changed.durations, vec![5., 1.]);
        assert_eq!(changed.known_durations, vec![false, false]);
    }
}
