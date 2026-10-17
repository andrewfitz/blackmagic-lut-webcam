use crate::model::{AudioCue, StreamEvent};
use anyhow::{bail, Context, Result};
use std::path::Path;
use std::process::{Command, Stdio};

pub struct PcmCueDecoder {
    sample_rate: u32,
    chunk_frames: usize,
    threshold: f32,
    next_frame: u64,
    next_id: u64,
    speaking: bool,
    silence_frames: u64,
    pending_bytes: Vec<u8>,
}

impl PcmCueDecoder {
    pub fn new(sample_rate: u32, chunk_ms: u32, threshold: f32) -> Result<Self> {
        if sample_rate == 0
            || chunk_ms == 0
            || !threshold.is_finite()
            || !(0.0..=1.0).contains(&threshold)
        {
            bail!("sample rate, chunk duration, and threshold must be valid");
        }
        let chunk_frames = ((sample_rate as u64 * chunk_ms as u64) / 1_000).max(1) as usize;
        Ok(Self {
            sample_rate,
            chunk_frames,
            threshold,
            next_frame: 0,
            next_id: 1,
            speaking: false,
            silence_frames: 0,
            pending_bytes: Vec::new(),
        })
    }

    pub fn push_pcm16le(&mut self, bytes: &[u8]) -> Vec<StreamEvent> {
        self.pending_bytes.extend_from_slice(bytes);
        let available_frames = self.pending_bytes.len() / 2;
        let complete_frames = available_frames / self.chunk_frames * self.chunk_frames;
        let complete_bytes = complete_frames * 2;
        let raw: Vec<u8> = self.pending_bytes.drain(..complete_bytes).collect();
        let (chunks, _) = raw.as_chunks::<2>();
        let samples: Vec<i16> = chunks
            .iter()
            .map(|chunk| i16::from_le_bytes(*chunk))
            .collect();
        let chunk_frames = self.chunk_frames;
        let mut events = Vec::new();
        for chunk in samples.chunks(chunk_frames) {
            if chunk.len() == chunk_frames {
                events.push(self.make_cue(chunk));
            }
        }
        events
    }

    pub fn finish(&mut self) -> Vec<StreamEvent> {
        let mut events = Vec::new();
        let complete_bytes = self.pending_bytes.len() / 2 * 2;
        if complete_bytes > 0 {
            let raw: Vec<u8> = self.pending_bytes.drain(..complete_bytes).collect();
            let (chunks, _) = raw.as_chunks::<2>();
            let samples: Vec<i16> = chunks
                .iter()
                .map(|chunk| i16::from_le_bytes(*chunk))
                .collect();
            if !samples.is_empty() {
                events.push(self.make_cue(&samples));
            }
        }
        if self.speaking {
            self.speaking = false;
            let id = self.next_id;
            self.next_id += 1;
            events.push(StreamEvent::Audio {
                cue: AudioCue {
                    id,
                    time: self.next_frame as f64 / self.sample_rate as f64,
                    duration: 0.0,
                    speech_energy: 0.0,
                    pause_duration: 0.0,
                    emphasis: 0.0,
                    laughter: 0.0,
                    speech_start: false,
                    speech_stop: true,
                    session_generation: 0,
                },
            });
        } else {
            // An odd trailing byte is malformed PCM and is intentionally
            // discarded after any complete final sample has been emitted.
        }
        self.pending_bytes.clear();
        events
    }

    fn make_cue(&mut self, samples: &[i16]) -> StreamEvent {
        let energy = (samples
            .iter()
            .map(|sample| (*sample as f32 / i16::MAX as f32).powi(2))
            .sum::<f32>()
            / samples.len() as f32)
            .sqrt()
            .min(1.0);
        let duration = samples.len() as f64 / self.sample_rate as f64;
        let time = self.next_frame as f64 / self.sample_rate as f64;
        self.next_frame += samples.len() as u64;
        let is_speech = energy >= self.threshold;
        let was_speaking = self.speaking;
        let speech_start = is_speech && !was_speaking;
        let speech_stop = !is_speech && was_speaking;
        if is_speech {
            self.speaking = true;
            self.silence_frames = 0;
        } else {
            self.silence_frames += samples.len() as u64;
            self.speaking = false;
        }
        let pause_duration = if !is_speech {
            self.silence_frames as f64 / self.sample_rate as f64
        } else {
            0.0
        };
        let cue = AudioCue {
            id: self.next_id,
            time,
            duration,
            speech_energy: energy,
            pause_duration,
            emphasis: energy,
            laughter: 0.0,
            speech_start,
            speech_stop,
            session_generation: 0,
        };
        self.next_id += 1;
        StreamEvent::Audio { cue }
    }
}

pub fn decode_wav(path: &Path) -> Result<(u32, Vec<u8>)> {
    let bytes =
        std::fs::read(path).with_context(|| format!("failed to read WAV {}", path.display()))?;
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        bail!("{} is not a RIFF/WAVE file", path.display());
    }
    let mut cursor = 12usize;
    let mut sample_rate = None;
    let mut channels = None;
    let mut bits_per_sample = None;
    let mut data = None;
    while cursor + 8 <= bytes.len() {
        let id = &bytes[cursor..cursor + 4];
        let size = u32::from_le_bytes(bytes[cursor + 4..cursor + 8].try_into()?) as usize;
        cursor += 8;
        if cursor + size > bytes.len() {
            bail!("truncated WAV chunk");
        }
        match id {
            b"fmt " if size >= 16 => {
                let format = u16::from_le_bytes(bytes[cursor..cursor + 2].try_into()?);
                if format != 1 {
                    bail!("only PCM WAV input is supported");
                }
                channels = Some(u16::from_le_bytes(
                    bytes[cursor + 2..cursor + 4].try_into()?,
                ));
                sample_rate = Some(u32::from_le_bytes(
                    bytes[cursor + 4..cursor + 8].try_into()?,
                ));
                bits_per_sample = Some(u16::from_le_bytes(
                    bytes[cursor + 14..cursor + 16].try_into()?,
                ));
            }
            b"data" => data = Some(bytes[cursor..cursor + size].to_vec()),
            _ => {}
        }
        cursor += size + (size % 2);
    }
    let rate = sample_rate.context("WAV fmt chunk missing")?;
    if channels != Some(1) || bits_per_sample != Some(16) {
        bail!("WAV input must be mono 16-bit PCM");
    }
    Ok((rate, data.context("WAV data chunk missing")?))
}

pub fn decode_media_audio(path: &Path, sample_rate: u32) -> Result<Vec<u8>> {
    let output = Command::new("ffmpeg")
        .args(["-v", "error", "-i"])
        .arg(path)
        .args(["-f", "s16le", "-ac", "1", "-ar"])
        .arg(sample_rate.to_string())
        .args(["pipe:1"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .with_context(|| "failed to start ffmpeg; install ffmpeg or use a WAV file")?;
    if !output.status.success() {
        bail!("ffmpeg failed: {}", String::from_utf8_lossy(&output.stderr));
    }
    Ok(output.stdout)
}
