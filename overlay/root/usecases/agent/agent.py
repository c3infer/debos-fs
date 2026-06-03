import os
import argparse
import time
import csv
import subprocess
import struct
from statistics import median

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
POLL_INTERVAL_S = 0.01


def parse_args():
    parser = argparse.ArgumentParser(description="Chatbot agent using rw_ivshmem -P/-C")
    parser.add_argument("--device", type=str, default="/tmp/shmfile")
    parser.add_argument("--rw-ivshmem", type=str, default="/root/rw_ivshmem")
    parser.add_argument("--channel", type=int, default=0, help="Accepted for CLI compatibility; unused by -P/-C mode")

    # Exp1 bench args
    parser.add_argument("--bench", action="store_true", help="Run IPC benchmark (Exp1)")
    parser.add_argument("--iters", type=int, default=1000)
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("--sizes", type=str, default="64,256,1024,4096,8192,16384")
    parser.add_argument("--csv", type=str, default="")

    # Exp2 workload args
    parser.add_argument("--workload", type=str, default="", help="Path to workload file (one prompt per line)")
    parser.add_argument("--repeat", type=int, default=1, help="Repeat workload N times")
    parser.add_argument("--e2e-csv", type=str, default="", help="Append Exp2 per-task timings to CSV")

    return parser.parse_args()


def format_prompt(text: str) -> str:
    return f"Q: {text}\nA:"


class RwIvshmemPipe:
    def __init__(self, device: str, rw_ivshmem: str, work_dir: str, prefix: str):
        self.device = device
        self.rw_ivshmem = rw_ivshmem
        self.produce_file = os.path.join(work_dir, f"{prefix}_produce.txt")
        self.consume_file = os.path.join(work_dir, f"{prefix}_consume.txt")

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

    def consume(self) -> bytes:
        subprocess.run(
            [self.rw_ivshmem, "-f", self.device, "-C", self.consume_file],
            check=True,
        )
        with open(self.consume_file, "rb") as f:
            return f.read()

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


def p95_ns(values_ns):
    if not values_ns:
        return 0
    vals = sorted(values_ns)
    k = int(0.95 * (len(vals) - 1))
    return vals[k]


def run_bench(pipe, sizes, iters, warmup, csv_path):
    out_rows = []
    for sz in sizes:
        payload = b"a" * sz
        rtts = []
        for _ in range(iters):
            t0 = time.perf_counter_ns()
            pipe.produce(payload)
            resp = pipe.consume()
            text = resp.decode("utf-8", errors="replace")
            print(f"[Resp] bytes={len(resp)} head={text[:80]!r}")
            t1 = time.perf_counter_ns()
            rtts.append(t1 - t0)
            if len(resp) != len(payload):
                raise RuntimeError(f"Echo length mismatch: sent={len(payload)} recv={len(resp)}")

        rtts = rtts[warmup:] if warmup < len(rtts) else rtts
        med = median(rtts)
        p95 = p95_ns(rtts)
        print(f"[Bench chatbot] size={sz}B median={med/1000:.1f}us p95={p95/1000:.1f}us n={len(rtts)}")

        out_rows.append(
            {
                "agent": "chatbot",
                "size_bytes": sz,
                "iters": iters,
                "warmup": warmup,
                "median_ns": int(med),
                "p95_ns": int(p95),
            }
        )

    if csv_path:
        write_header = not os.path.exists(csv_path)
        with open(csv_path, "a", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(out_rows[0].keys()))
            if write_header:
                w.writeheader()
            w.writerows(out_rows)


def load_chat_workload(path: str):
    prompts = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            prompts.append(s)
    return prompts


def append_e2e_rows(csv_path: str, rows: list):
    if not csv_path or not rows:
        return
    write_header = not os.path.exists(csv_path)
    with open(csv_path, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        if write_header:
            w.writeheader()
        w.writerows(rows)


def run_workload_e2e(pipe, prompts, repeat, e2e_csv):
    timings = []
    task_idx = 0

    for r in range(repeat):
        for prompt_text in prompts:
            task_idx += 1
            prompt = format_prompt(prompt_text)
            payload = prompt.encode("utf-8")

            t0 = time.perf_counter_ns()
            pipe.produce(payload)
            resp = pipe.consume()
            t1 = time.perf_counter_ns()

            elapsed_ns = t1 - t0
            timings.append(elapsed_ns)

            print(f"[Exp2 chatbot] task={task_idx} bytes={len(payload)} time={elapsed_ns/1e9:.3f}s")
            # Optional: keep output short in batch mode
            _ = resp  # you can print resp.decode(...) if you want

    avg_s = (sum(timings) / len(timings)) / 1e9 if timings else 0.0
    print(f"[Exp2 chatbot] done tasks={len(timings)} avg_time={avg_s:.3f}s")

    rows = []
    for i, ns in enumerate(timings, start=1):
        rows.append(
            {
                "agent": "chatbot",
                "task_id": i,
                "time_ns": int(ns),
                "time_s": ns / 1e9,
            }
        )
    append_e2e_rows(e2e_csv, rows)


def main():
    args = parse_args()
    pipe = RwIvshmemPipe(args.device, args.rw_ivshmem, SCRIPT_DIR, "agent")

    print(
        f"[Agent] Ready (device={args.device}, rw_ivshmem={args.rw_ivshmem}, "
        f"mode=producer-consumer)"
    )

    if args.bench:
        sizes = [int(x) for x in args.sizes.split(",") if x.strip()]
        run_bench(pipe, sizes, args.iters, args.warmup, args.csv)
        return

    # Exp2 workload mode (batch)
    if args.workload:
        prompts = load_chat_workload(args.workload)
        if not prompts:
            raise RuntimeError(f"No prompts found in workload: {args.workload}")
        run_workload_e2e(pipe, prompts, args.repeat, args.e2e_csv)
        return

    # Exp2 interactive mode (single prompt)
    user_text = input("Ask something: ")
    prompt = format_prompt(user_text)
    payload = prompt.encode("utf-8")

    t0 = time.perf_counter_ns()
    pipe.produce(payload)
    resp = pipe.consume()
    t1 = time.perf_counter_ns()

    print(f"[Exp2 chatbot] time={(t1 - t0)/1e9:.3f}s")
    print(resp.decode("utf-8", errors="replace"))


if __name__ == "__main__":
    main()
