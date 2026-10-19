use auto_switcher::audio::PcmCueDecoder;
use auto_switcher::director::DirectorState;
use auto_switcher::model::{
    AudioCue, CueKind, CutReason, StreamEvent, SwitcherConfig, TranscriptCue,
};
use auto_switcher::Director;

fn config() -> SwitcherConfig {
    SwitcherConfig {
        minimum_shot_duration: 0.0,
        cooldown: 0.0,
        emphasis_hold: 0.0,
        soft_maximum_shot_duration: 2.0,
        candidate_dwell: 0.0,
        boundary_window: 0.3,
        maximum_shot_duration: 3.0,
        forced_cut_grace_period: 1.0,
        forced_boundary_lookback: 0.5,
        ..SwitcherConfig::default()
    }
}

#[test]
fn default_minimum_shot_duration_is_ten_seconds() {
    assert_eq!(SwitcherConfig::default().minimum_shot_duration, 10.0);
}

fn audio(time: f64, emphasis: f32, pause_duration: f64) -> StreamEvent {
    StreamEvent::Audio {
        cue: AudioCue {
            id: (time * 100.0) as u64,
            time,
            duration: 0.02,
            speech_energy: emphasis,
            pause_duration,
            emphasis,
            laughter: 0.0,
            speech_start: false,
            speech_stop: false,
            session_generation: 0,
        },
    }
}

#[test]
fn normal_cut_is_emitted_and_acknowledged_once() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(audio(1.0, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    let output = director.process_event(StreamEvent::Tick { time: 1.0 });
    let instruction = match &output[0] {
        auto_switcher::SwitcherOutput::Cut { instruction } => instruction.clone(),
        other => panic!("unexpected output: {other:?}"),
    };
    assert_eq!(instruction.target_camera_id, "B");
    assert!(!instruction.forced);
    assert!(director.acknowledge(instruction.decision_id, Some(1.0)));
    assert!(!director.acknowledge(instruction.decision_id, Some(1.0)));
    assert_eq!(director.current_camera_id(), "B");
}

#[test]
fn hard_maximum_prefers_nearest_gap_then_uses_absolute_cap() {
    let mut director = Director::new(config()).expect("valid config");
    assert!(director.tick(3.0).is_none());
    assert_eq!(director.state(), DirectorState::ForcedCutPending);
    director.process_event(audio(3.5, 0.0, 0.3));
    let instruction = director.tick(3.5).expect("gap in forced grace should cut");
    assert!(instruction.forced);
    assert_eq!(instruction.reason, CutReason::ForcedMaximumShotDuration);
    assert_eq!(instruction.cut_time, 3.5);
    assert!(director.acknowledge(instruction.decision_id, Some(3.5)));

    let mut second = Director::new(config()).expect("valid config");
    assert!(
        second.tick(4.1).is_some(),
        "absolute cap must not wait indefinitely"
    );
}

#[test]
fn revised_transcript_replaces_non_final_cue_without_duplicate_cut() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.5,
            is_final: false,
            session_generation: 0,
        },
    });
    director.process_event(audio(1.0, 1.0, 0.0));
    assert!(director.tick(1.0).is_none());
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 2,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    let instruction = director
        .tick(1.0)
        .expect("final revision should become eligible");
    assert!(director.acknowledge(instruction.decision_id, Some(1.0)));
    assert!(director.tick(1.1).is_none());
}

#[test]
fn pcm_decoder_handles_arbitrary_realtime_read_boundaries() {
    let mut decoder = PcmCueDecoder::new(1_000, 20, 0.01).expect("valid decoder");
    let sample = 20_000_i16.to_le_bytes();
    let bytes: Vec<u8> = std::iter::repeat_n(sample, 40).flatten().collect();
    let mut events = Vec::new();
    for byte in bytes {
        events.extend(decoder.push_pcm16le(&[byte]));
    }
    assert_eq!(events.len(), 2);
    assert!(matches!(
        events[0],
        auto_switcher::StreamEvent::Audio { .. }
    ));
}

#[test]
fn stale_audio_falls_back_from_emphasis_to_anchor() {
    let mut director = Director::new(config()).expect("valid config");
    director.manual_override("B".to_string(), 1.0);
    let instruction = director.tick(3.0).expect("stale audio should fallback");
    assert_eq!(instruction.target_camera_id, "A");
    assert_eq!(instruction.reason, CutReason::AudioDegradedFallback);
}

#[test]
fn invalid_video_and_ack_times_do_not_poison_director_state() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(StreamEvent::Video {
        observation: auto_switcher::VideoObservation {
            time: f64::NAN,
            camera_id: "A".into(),
            healthy: false,
            motion: 0.0,
            scene_change: 0.0,
            session_generation: 0,
        },
    });
    assert!(director.tick(1.0).is_none());
    director.manual_override("B".into(), 1.0);
    let instruction = director.tick(4.0).expect("stale audio fallback");
    assert!(!director.acknowledge(instruction.decision_id, Some(f64::NAN)));
    assert!(director.pending().is_some());
    assert!(director.acknowledge(instruction.decision_id, Some(4.0)));
}

#[test]
fn candidate_dwell_starts_when_candidate_is_observed() {
    let mut cfg = config();
    cfg.candidate_dwell = 1.0;
    let mut director = Director::new(cfg).expect("valid config");
    director.process_event(audio(1.1, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "late".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 1.0,
            is_final: true,
            session_generation: 0,
        },
    });
    assert!(director.tick(1.1).is_none());
    assert!(director.tick(1.9).is_none());
    assert!(director.tick(2.2).is_some());
}

#[test]
fn backward_clock_keeps_the_current_camera_and_shot_age() {
    let mut cfg = config();
    cfg.maximum_shot_duration = 30.0;
    cfg.soft_maximum_shot_duration = 20.0;
    cfg.forced_cut_grace_period = 2.0;
    let mut director = Director::new(cfg).expect("valid config");
    director.manual_override("B".to_string(), 1.0);
    // Keep a live audio cue so the emphasis camera is not treated as silent.
    director.process_event(audio(25.0, 0.1, 0.0));
    assert!(director.tick(25.0).is_none());
    assert_eq!(director.current_camera_id(), "B");
    assert!(
        director.tick(24.5).is_none(),
        "a small backward step must not manufacture a cut"
    );
    assert_eq!(director.current_camera_id(), "B");
    assert_eq!(director.session_generation(), 2);
    director.process_event(audio(34.0, 0.1, 0.0));
    assert!(
        director.tick(34.0).is_none(),
        "shot age restarts at the discontinuity, not at zero"
    );
}

#[test]
fn backward_clock_expires_a_pending_cut_without_replacing_it() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(audio(1.0, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    let first = director.process_event(StreamEvent::Tick { time: 1.0 });
    assert!(matches!(
        first.first(),
        Some(auto_switcher::SwitcherOutput::Cut { .. })
    ));
    let output = director.process_event(StreamEvent::Tick { time: 0.2 });
    assert!(
        output.iter().any(|item| matches!(
            item,
            auto_switcher::SwitcherOutput::DecisionExpired { .. }
        )),
        "the pending decision belongs to the old clock: {output:?}"
    );
    assert!(
        output
            .iter()
            .all(|item| !matches!(item, auto_switcher::SwitcherOutput::Cut { .. })),
        "a discontinuity must not immediately request another cut: {output:?}"
    );
    assert_eq!(director.current_camera_id(), "A");
    assert!(director.pending().is_none());
}

#[test]
fn unhealthy_current_camera_cuts_to_the_other_camera() {
    let mut director = Director::new(config()).expect("valid config");
    director.manual_override("B".to_string(), 1.0);
    director.ingest_video(auto_switcher::VideoObservation {
        time: 1.2,
        camera_id: "B".into(),
        healthy: false,
        motion: 0.0,
        scene_change: 0.0,
        session_generation: 0,
    });
    let instruction = director.tick(1.2).expect("health fallback");
    assert_eq!(instruction.target_camera_id, "A");
    assert_eq!(instruction.reason, CutReason::CameraHealthFallback);
    assert!(instruction.forced);
}

#[test]
fn unhealthy_pending_target_is_dropped_instead_of_cut() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(audio(1.0, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    assert!(matches!(
        director
            .process_event(StreamEvent::Tick { time: 1.0 })
            .first(),
        Some(auto_switcher::SwitcherOutput::Cut { .. })
    ));
    director.ingest_video(auto_switcher::VideoObservation {
        time: 1.0,
        camera_id: "B".into(),
        healthy: false,
        motion: 0.0,
        scene_change: 0.0,
        session_generation: 0,
    });
    let output = director.process_event(StreamEvent::Tick { time: 1.0 });
    assert!(output.iter().any(|item| matches!(
        item,
        auto_switcher::SwitcherOutput::DecisionExpired { .. }
    )));
    assert!(output
        .iter()
        .all(|item| !matches!(item, auto_switcher::SwitcherOutput::Cut { .. })));
    assert_eq!(director.current_camera_id(), "A");
}

#[test]
fn acknowledge_does_not_pull_the_live_clock_forward() {
    let mut director = Director::new(config()).expect("valid config");
    director.process_event(audio(1.0, 1.0, 0.0));
    director.process_event(StreamEvent::Transcript {
        cue: TranscriptCue {
            segment_id: "s1".into(),
            revision: 1,
            start: 0.8,
            end: 1.0,
            kind: CueKind::SentenceEnd,
            confidence: 0.95,
            is_final: true,
            session_generation: 0,
        },
    });
    let instruction = director.tick(1.0).expect("cut");
    assert!(director.acknowledge(instruction.decision_id, Some(5.0)));
    assert!(director.tick(1.2).is_none());
    assert_eq!(
        director.session_generation(),
        1,
        "acking a later boundary must not make the next cue discontinuous"
    );
}

#[test]
fn manual_override_accepts_a_recent_lagging_clock() {
    let mut cfg = config();
    cfg.maximum_shot_duration = 30.0;
    cfg.soft_maximum_shot_duration = 20.0;
    let mut director = Director::new(cfg).expect("valid config");
    assert!(director.tick(10.0).is_none());
    director.manual_override("B".to_string(), 9.5);
    assert_eq!(director.current_camera_id(), "B");
}

#[test]
fn clock_reset_accepts_generation_zero_cues_after_advancing_session() {
    let mut director = Director::new(config()).expect("valid config");
    assert!(director.tick(1.0).is_none());
    assert!(director.tick(0.5).is_none());
    assert_eq!(director.session_generation(), 2);
    director.ingest_audio(auto_switcher::AudioCue {
        id: 1,
        time: 0.5,
        duration: 0.02,
        speech_energy: 0.5,
        pause_duration: 0.0,
        emphasis: 0.5,
        laughter: 0.0,
        speech_start: true,
        speech_stop: false,
        session_generation: 0,
    });
    assert!(director.tick(0.5).is_none());
}
