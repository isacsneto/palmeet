// AudioWorklet: collects Float32 input blocks into ~100 ms chunks of interleaved Int16 PCM
// and posts them (transferred) to the offscreen document.

class PcmCaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const opts = options?.processorOptions ?? {};
    this.channels = opts.channels ?? 2;
    this.chunkFrames = opts.chunkFrames ?? Math.round(sampleRate / 10);
    this.reset();
    this.port.onmessage = (event) => {
      if (event.data === 'flush') this.flush();
    };
  }

  reset() {
    this.buffer = new Int16Array(this.chunkFrames * this.channels);
    this.frames = 0;
    this.chunkStartTime = null;
  }

  flush() {
    if (this.frames === 0) return;
    const pcm = this.buffer.slice(0, this.frames * this.channels);
    this.port.postMessage(
      { pcm: pcm.buffer, frames: this.frames, channels: this.channels, startTime: this.chunkStartTime },
      [pcm.buffer]
    );
    this.reset();
  }

  process(inputs) {
    const input = inputs[0] ?? [];
    const blockFrames = input[0]?.length ?? 128;
    for (let i = 0; i < blockFrames; i++) {
      if (this.frames === 0) this.chunkStartTime = currentTime + i / sampleRate;
      const base = this.frames * this.channels;
      for (let ch = 0; ch < this.channels; ch++) {
        // Mono input is duplicated; missing input (no channels) is silence.
        const source = input[ch] ?? input[0];
        let s = source ? source[i] : 0;
        s = s > 1 ? 1 : s < -1 ? -1 : s;
        this.buffer[base + ch] = s < 0 ? s * 0x8000 : s * 0x7fff;
      }
      this.frames++;
      if (this.frames === this.chunkFrames) this.flush();
    }
    return true;
  }
}

registerProcessor('pcm-capture', PcmCaptureProcessor);
