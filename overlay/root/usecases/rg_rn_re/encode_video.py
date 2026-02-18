#!/usr/bin/env python3
"""
encode_video.py

Simple wrapper around ffmpeg to re-encode an MP4 using x264 or NVENC.

Usage:
    python encode_video.py input.mp4 output.mp4
    python encode_video.py input.mp4 output.mp4 --width 320 --height 180
    python encode_video.py input.mp4 output.mp4 --nvenc
"""

import argparse
import subprocess

try:
    import ffmpeg  # type: ignore
except Exception:
    ffmpeg = None


def encode_video(input_path: str,
                 output_path: str,
                 width: int = 320,
                 height: int = 180,
                 use_nvenc: bool = False) -> None:
    vcodec = "h264_nvenc" if use_nvenc else "libx264"

    if ffmpeg is not None:
        stream = (
            ffmpeg
            .input(input_path)
            .output(
                output_path,
                vcodec=vcodec,
                vf=f"scale={width}:{height}",
                pix_fmt="yuv420p",
                preset="veryfast",
                crf=28,
                an=None  # drop audio to keep things small/simple
            )
            .overwrite_output()
        )

        stream.run()
        return

    subprocess.run(
        [
            "ffmpeg", "-y", "-i", input_path,
            "-vf", f"scale={width}:{height}",
            "-vcodec", vcodec,
            "-pix_fmt", "yuv420p",
            "-preset", "veryfast",
            "-crf", "28",
            "-an",
            output_path,
        ],
        check=True,
    )


def parse_args():
    p = argparse.ArgumentParser(description="Re-encode an MP4 video.")
    p.add_argument("input", help="Input MP4 file")
    p.add_argument("output", help="Output MP4 file")
    p.add_argument("--width", type=int, default=320, help="Output width (default: 320)")
    p.add_argument("--height", type=int, default=180, help="Output height (default: 180)")
    p.add_argument("--nvenc", action="store_true",
                   help="Use NVIDIA NVENC (h264_nvenc) instead of libx264")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    encode_video(
        input_path=args.input,
        output_path=args.output,
        width=args.width,
        height=args.height,
        use_nvenc=args.nvenc,
    )
    print(f"Encoded {args.input} -> {args.output}")
