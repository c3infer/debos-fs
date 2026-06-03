import os
import argparse
import time
import csv
import subprocess
import struct
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LLAMA_CLI = os.path.abspath(os.path.join(SCRIPT_DIR, "../rg_rf_ri/llama-cli"))
POLL_INTERVAL_S = 0.01


def parse_args():
    parser = argparse.ArgumentParser(description="LLM worker using rw_ivshmem -C/-P")
    parser.add_argument(
        "--model",
        type=str,
        default="../models/gpt2-large-q8_0.gguf",
        help="Path to GGUF model file",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="/tmp/shmfile",
        help="Path to shared memory / device file",
    )
    parser.add_argument(
        "--rw-ivshmem",
        type=str,
        default="/root/rw_ivshmem",
        help="Path to rw_ivshmem helper",
    )
    parser.add_argument(
        "--llama-cli",
        type=str,
        default=DEFAULT_LLAMA_CLI,
        help="Path to llama-cli executable",
    )
    parser.add_argument(
        "--channel",
        type=int,
        default=0,
        help="Accepted for CLI compatibility; unused by -P/-C mode",
    )
    parser.add_argument(
        "--echo",
        action="store_true",
        help="Echo prompt back (no inference). Used for Exp1 IPC microbenchmark.",
    )
    parser.add_argument(
        "--n-ctx",
        type=int,
        default=1024,
        help="Context size for inference (Exp2).",
    )
    parser.add_argument(
        "--n-threads",
        type=int,
        default=4,
        help="Threads for inference (Exp2).",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=80,
        help="Max tokens to generate (Exp2).",
    )
    parser.add_argument(
        "--max-inferences",
        type=int,
        default=0,
        help="Maximum number of requests to process before exit (0 = unlimited)",
    )
    parser.add_argument(
        "--infer-csv",
        type=str,
        default="",
        help="Append per-inference timings to CSV",
    )
    return parser.parse_args()


class RwIvshmemPipe:
    def __init__(self, device: str, rw_ivshmem: str, work_dir: str, prefix: str):
        self.device = device
        self.rw_ivshmem = rw_ivshmem
        self.consume_file = os.path.join(work_dir, f"{prefix}_consume.txt")
        self.produce_file = os.path.join(work_dir, f"{prefix}_produce.txt")

    def consume(self) -> bytes:
        subprocess.run(
            [self.rw_ivshmem, "-f", self.device, "-C", self.consume_file],
            check=True,
        )
        with open(self.consume_file, "rb") as f:
            return f.read()

    def produce(self, payload: bytes) -> None:
        write_cnt, _ = self.read_counters()
        target_read_cnt = (write_cnt + 1) & 0xFFFFFFFF
        with open(self.produce_file, "wb") as f:
            f.write(payload)
        subprocess.run(
            [self.rw_ivshmem, "-f", self.device, "-P", self.produce_file],
            check=True,
        )
        self.wait_consumed(target_read_cnt)

    def read_counters(self):
        result = subprocess.run(
            [self.rw_ivshmem, "-f", self.device, "-R", "32"],
            check=True,
            stdout=subprocess.PIPE,
        )
        header = result.stdout[:8]
        if len(header) != 8:
            raise RuntimeError("Failed to read rw_ivshmem header counters")
        return struct.unpack("<II", header)

    def wait_consumed(self, target_read_cnt: int) -> None:
        while True:
            _, read_cnt = self.read_counters()
            if read_cnt == target_read_cnt:
                return
            time.sleep(POLL_INTERVAL_S)


def append_infer_rows(csv_path: str, rows: list) -> None:
    if not csv_path or not rows:
        return
    write_header = not os.path.exists(csv_path)
    with open(csv_path, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        if write_header:
            w.writeheader()
        w.writerows(rows)


def run_llama_cli(llama_cli: str, model_path: str, prompt: str, max_tokens: int) -> str:
    result = subprocess.run(
        [
            llama_cli,
            "-m",
            model_path,
            "-p",
            prompt,
            "-n",
            str(max_tokens),
            "--no-display-prompt",
            "--temp",
            "0.3",
        ],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def main():
    args = parse_args()
    device = args.device
    model_path = args.model
    pipe = RwIvshmemPipe(device, args.rw_ivshmem, SCRIPT_DIR, "model")

    if not args.echo and not os.access(args.llama_cli, os.X_OK):
        raise RuntimeError(f"missing executable llama-cli: {args.llama_cli}")

    served = 0
    rows = []

    print(
        f"[Model] Ready (model={model_path}, device={device}, "
        f"rw_ivshmem={args.rw_ivshmem}, mode=consumer-producer, "
        f"llama_cli={args.llama_cli}, echo={args.echo}, max_inferences={args.max_inferences})"
    )

    try:
        while True:
            if args.max_inferences > 0 and served >= args.max_inferences:
                print(f"[Model] max inferences reached ({served}); exiting.")
                break

            print("[Model] Waiting for prompt...")
            prompt_data = pipe.consume()
            prompt = prompt_data.decode("utf-8", errors="replace")
            print(f"[Model] Got prompt bytes={len(prompt_data)}")

            t0 = time.perf_counter_ns()
            if args.echo:
                output = prompt
            else:
                try:
                    print(
                        f"[Model] Running llama-cli max_tokens={args.max_tokens}...",
                        flush=True,
                    )
                    output = run_llama_cli(args.llama_cli, model_path, prompt, args.max_tokens)
                except Exception as e:
                    output = f"[error] inference failed: {e}"
            t1 = time.perf_counter_ns()

            served += 1
            output_data = output.encode("utf-8", errors="replace")
            infer_time_ns = t1 - t0
            print(f"[Model] inference={served} infer_time={infer_time_ns/1e9:.3f}s")
            rows.append(
                {
                    "agent": "chatbot_model",
                    "inference_id": served,
                    "timestamp": datetime.now().isoformat(timespec="seconds"),
                    "model": args.model,
                    "channel": args.channel,
                    "prompt_bytes": len(prompt_data),
                    "output_bytes": len(output_data),
                    "infer_time_ns": int(infer_time_ns),
                    "infer_time_s": infer_time_ns / 1e9,
                }
            )

            pipe.produce(output_data)
    finally:
        append_infer_rows(args.infer_csv, rows)


if __name__ == "__main__":
    main()
