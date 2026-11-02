# SPDX-License-Identifier: GPL-3.0-or-later
# Writes when speech happens in a video, as an SRT, for timing a subtitle
# against. The text is whatever Whisper heard; only the times matter.
#
#   python whisper_ref.py <audio.wav> <out.srt> [--model PATH_OR_NAME] [--device cuda|cpu]
import argparse
import sys
import wave


def stamp(seconds):
    millis = int(round(seconds * 1000))
    hours, millis = divmod(millis, 3600000)
    minutes, millis = divmod(millis, 60000)
    secs, millis = divmod(millis, 1000)
    return f"{hours:02}:{minutes:02}:{secs:02},{millis:03}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("media")
    parser.add_argument("out")
    parser.add_argument("--model", default="large-v3")
    parser.add_argument("--device", default="cuda")
    args = parser.parse_args()

    import numpy
    from faster_whisper import WhisperModel

    # The audio comes as 16 kHz mono 16-bit WAV, made by mpv's ffmpeg, so
    # nothing here depends on PyAV's version.
    with wave.open(args.media, "rb") as source:
        if source.getframerate() != 16000 or source.getnchannels() != 1 or source.getsampwidth() != 2:
            sys.exit("the audio must be 16 kHz mono 16-bit WAV")
        audio = numpy.frombuffer(source.readframes(source.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768

    def listen(device):
        compute = "float16" if device == "cuda" else "int8"
        model = WhisperModel(args.model, device=device, compute_type=compute)
        segments, _ = model.transcribe(audio, language="ja", vad_filter=True,
                                       condition_on_previous_text=False, beam_size=1)
        return [segment for segment in segments if segment.end > segment.start]

    try:
        segments = listen(args.device)
    except Exception as error:  # no GPU, or no CUDA libraries: the CPU is slower but works
        if args.device == "cpu":
            raise
        print(f"{args.device} failed ({error}); using the CPU", file=sys.stderr)
        segments = listen("cpu")
    with open(args.out, "w", encoding="utf-8") as out:
        for count, segment in enumerate(segments, 1):
            out.write(f"{count}\n{stamp(segment.start)} --> {stamp(segment.end)}\n{segment.text.strip()}\n\n")
    print(f"segments={len(segments)}", file=sys.stderr)


if __name__ == "__main__":
    main()
