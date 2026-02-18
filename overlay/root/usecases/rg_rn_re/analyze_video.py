#!/usr/bin/env python3
"""
analyze_video.py

Analyze a (YouTube-derived) MP4:
- Simple scene detection via frame differences
- Thumbnail extraction (middle frame of each scene)
- Optional NSFW filtering using NudeNet

Usage:
    python analyze_video.py encoded.mp4
    python analyze_video.py encoded.mp4 --thumb-dir thumbs/
    python analyze_video.py encoded.mp4 --thumb-dir thumbs/ --nsfw-threshold 0.6
"""

import argparse
import os
import subprocess
from typing import List, Tuple, Optional

import cv2
import numpy as np

# Try to import NudeNet (pip install nudenet)
try:
    from nudenet import NudeDetector
    HAVE_NUDENET = True
except ImportError:
    NudeDetector = None  # type: ignore
    HAVE_NUDENET = False


# --------- Scene detection & frame extraction ---------

def detect_scenes(
    video_path: str,
    threshold: float = 30.0,
    sample_every: int = 1
) -> List[Tuple[int, int]]:
    """
    Very simple scene detection based on frame-to-frame mean pixel difference.

    Returns a list of (start_frame, end_frame) for each detected scene.
    """
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Could not open video: {video_path}")

    scenes: List[Tuple[int, int]] = []
    ok, prev = cap.read()
    if not ok:
        cap.release()
        return scenes

    frame_idx = 0
    scene_start = 0

    while True:
        ok, frame = cap.read()
        if not ok:
            break

        frame_idx += 1
        if frame_idx % sample_every != 0:
            prev = frame
            continue

        diff = cv2.absdiff(frame, prev)
        score = float(diff.mean())

        if score > threshold:
            # scene cut detected at frame_idx
            scenes.append((scene_start, frame_idx - 1))
            scene_start = frame_idx

        prev = frame

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if scene_start < total_frames:
        scenes.append((scene_start, total_frames - 1))

    cap.release()
    return scenes


def extract_frame(video_path: str, frame_idx: int) -> Optional[np.ndarray]:
    """
    Extract a single frame at the given frame index.
    """
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        return None
    cap.set(cv2.CAP_PROP_POS_FRAMES, frame_idx)
    ok, frame = cap.read()
    cap.release()
    return frame if ok else None


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


# --------- NSFW detection via NudeNet ---------

def load_nsfw_detector() -> Optional[NudeDetector]:
    """
    Load NudeNet's built-in NudeDetector, if available.
    """
    if not HAVE_NUDENET:
        print("[!] NudeNet is not installed. Run: pip install nudenet")
        return None

    print("[+] Initializing NudeNet NudeDetector (first run may download a model) ...")
    detector = NudeDetector()  # uses built-in ONNX model
    return detector


def is_safe_thumbnail(
    detector,
    img_path: str,
    nsfw_threshold: float = 0.5
) -> bool:
    """
    Use NudeNet's detector to decide if a thumbnail is safe.

    If detector is None, all thumbnails are treated as safe.

    Rule:
      - If any detection has label containing 'exposed' and score >= threshold,
        treat as NSFW (unsafe).
    """
    if detector is None:
        return True

    detections = detector.detect(img_path)  # list of dicts: {label, score, box}
    for det in detections:
        label = str(det.get("label", "")).lower()
        score = float(det.get("score", 0.0))
        if "exposed" in label and score >= nsfw_threshold:
            return False  # unsafe

    return True  # no clearly exposed parts -> safe


# --------- Main pipeline ---------

def analyze_video(
    video_path: str,
    thumb_dir: str = "thumbs",
    scene_threshold: float = 30.0,
    nsfw_threshold: float = 0.5,
    use_nsfw: bool = True,
    output_video: Optional[str] = None,
):
    """
    Full pipeline:
      - detect scenes in the (YouTube-derived) MP4
      - extract thumbnails for each scene
      - optionally filter thumbnails with NudeNet
    """
    ensure_dir(thumb_dir)

    print(f"[+] Detecting scenes in {video_path} ...")
    scenes = detect_scenes(video_path, threshold=scene_threshold)
    print(f"[+] Found {len(scenes)} scenes")

    detector = load_nsfw_detector() if use_nsfw else None

    safe_thumbs = []

    for i, (start, end) in enumerate(scenes):
        mid = (start + end) // 2
        frame = extract_frame(video_path, mid)
        if frame is None:
            continue

        thumb_path = os.path.join(thumb_dir, f"scene_{i:03d}.jpg")
        cv2.imwrite(thumb_path, frame)

        try:
            if is_safe_thumbnail(detector, thumb_path, nsfw_threshold):
                safe_thumbs.append(thumb_path)
                print(f"  [SAFE]  Scene {i} -> {thumb_path}")
            else:
                print(f"  [NSFW]  Scene {i} -> {thumb_path} (filtered)")
        except Exception as e:
            print(f"  [ERROR] Scene {i} -> {thumb_path} (classification error: {e})")

    print("\n[+] Summary:")
    print(f"  Total scenes: {len(scenes)}")
    print(f"  Safe thumbnails: {len(safe_thumbs)}")
    for t in safe_thumbs:
        print(f"   - {t}")

    if output_video:
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-i", video_path, "-c", "copy", output_video],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            # Fallback if ffmpeg copy path is unavailable.
            with open(video_path, "rb") as src, open(output_video, "wb") as dst:
                dst.write(src.read())
        print(f"[+] Output video written: {output_video}")


def parse_args():
    p = argparse.ArgumentParser(
        description="Thumbnail picking from a (YouTube-derived) MP4 via scene detection and NudeNet.")
    p.add_argument("video", help="Input MP4 video (e.g. encoded.mp4 from encode_youtube.py)")
    p.add_argument("--thumb-dir", default="thumbs",
                   help="Directory to save thumbnails (default: thumbs/)")
    p.add_argument("--scene-threshold", type=float, default=30.0,
                   help="Frame-diff threshold for scene changes (default: 30.0)")
    p.add_argument("--nsfw-threshold", type=float, default=0.5,
                   help="Threshold for NudeNet NSFW score (default: 0.5)")
    p.add_argument("--no-nsfw", action="store_true",
                   help="Disable NSFW filtering and treat all thumbnails as safe.")
    p.add_argument("--output-video", default=None,
                   help="Optional output MP4 path to forward after analysis.")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    analyze_video(
        video_path=args.video,
        thumb_dir=args.thumb_dir,
        scene_threshold=args.scene_threshold,
        nsfw_threshold=args.nsfw_threshold,
        use_nsfw=not args.no_nsfw,
        output_video=args.output_video,
    )
