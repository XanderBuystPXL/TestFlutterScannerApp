"""Run the existing GPU PoC with explicit iPhone roles and sensor depth, without editing it."""
import argparse
import hashlib
import importlib
from pathlib import Path
import sys

import numpy as np

from capture_pipeline import json_bytes, require, write_json
from capture_scene import CaptureScene, scene_arrays


def preflight(data, factor):
    data = Path(data)
    config, train, val, worlds, sizes, Ks, _, _ = scene_arrays(data, factor)
    report = json_bytes((data / "sensor_depth" / "report.json").read_bytes())
    require(report["normalization"] == config["normalization"] and
            report["scene_names"] == [f["name"] for f in config["frames"]], "Depth normalization/order differs.")
    require({v["index"] for v in report["views"]} == set(train), "Depth supervision must include training frames only.")
    for row in report["views"]:
        i = row["index"]
        with np.load(data / "sensor_depth" / row["file"], allow_pickle=False) as item:
            K = Ks[i].copy()
            K[0] *= item["depth"].shape[1]/sizes[i][0]
            K[1] *= item["depth"].shape[0]/sizes[i][1]
            require(np.allclose(K, item["K"], atol=.05, rtol=1e-4), "Sensor depth rays differ from resized RGB.")
            require(item["mask"].shape == item["depth"].shape and
                    np.isfinite(item["depth"]).all(), "Invalid normalized depth.")
    return {"training_views": len(train), "check_views": len(val), "normalization": config["normalization"],
            "source_scan_id": config["source_scan_id"], "roles_disjoint": not set(train).intersection(val),
            "protocol": config["validation_protocol"], "heldout_metrics_available": bool(val),
            "coverage_assessment": "not_recorded" if config.get("source_coverage") is None else "recorded",
            "coverage_warning": bool(config.get("source_capture_warning")) or (config.get("source_coverage") is not None and not config["source_coverage"]["coverage_passed"])}


def no_holdout_evaluation(params, scene, out, step, degree, antialiased, **kwargs):
    """No fabricated scores or training-view scores presented as held-out results."""
    report = {"step": step, "status": "not_evaluated_all_frames_used_for_fitting", "views": [],
              "mean_psnr": None, "mean_ssim": None, "note": "No held-out views exist in this all-frame fit."}
    folder = Path(out) / "eval" / f"step-{step:06d}"
    folder.mkdir(parents=True, exist_ok=True)
    write_json(folder / "metrics.json", report)
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("data")
    p.add_argument("--poc-root", type=Path)
    p.add_argument("--out", type=Path)
    p.add_argument("--steps", type=int, default=3000)
    p.add_argument("--factor", type=int, default=2)
    p.add_argument("--check-only", action="store_true")
    p.add_argument("--allow-coverage-warnings", action="store_true", help="Explicitly run a diagnostic reconstruction from a capture marked as needing more views.")
    p.add_argument("--alignment-reviewed", action="store_true", help="Confirm physical RGB/depth, camera path and RoomPlan alignment were reviewed.")
    args = p.parse_args()
    result = preflight(args.data, args.factor)
    if args.check_only:
        print(result)
        return
    require(args.poc_root is not None and args.out is not None, "Supply --poc-root and --out for GPU training.")
    require(args.alignment_reviewed, "Review alignment PNGs, preview.ply and RoomPlan geometry first; see docs/ACCEPTANCE.md.")
    require(not result["coverage_warning"] or args.allow_coverage_warnings,
            "Capture carries coverage or capture-condition warnings. Use --allow-coverage-warnings only for an explicitly labelled diagnostic trial.")
    alignment = json_bytes((Path(args.data) / "geometry" / "alignment.json").read_bytes())
    require(alignment["status"] == "matched_geometry_requires_physical_review",
            "RoomPlan/live geometry did not yield a consistent alignment. Resolve this before the full-pipeline test.")
    poc = args.poc_root.resolve()
    sys.path.insert(0, str(poc / "reused"))
    sys.path.insert(0, str(poc))
    trainer = importlib.import_module("roomscan.train")
    # Scoped to this Python process. The Android/SfM loader would recreate an interleaved
    # split and leak the separately recorded validation pass into training.
    trainer.Scene = CaptureScene
    if not result["heldout_metrics_available"]:
        trainer.evaluate = no_holdout_evaluation
    trainer.train(args.data, args.out, steps=args.steps, factor=args.factor,
                  eval_every=max(1, args.steps//3), save_every=max(1, args.steps//3),
                  depth_dir=Path(args.data) / "sensor_depth")
    result["coverage_warning_override"] = args.allow_coverage_warnings
    result["alignment_reviewed_by_operator"] = True
    result["trainer_source_sha256"] = hashlib.sha256(Path(trainer.__file__).read_bytes()).hexdigest()
    result["adapter_source_sha256"] = hashlib.sha256(Path(__file__).with_name("capture_scene.py").read_bytes()).hexdigest()
    write_json(args.out / "iphone-intake.json", result)
    print("Training complete. Review the splat in the target viewer. " +
          ("Held-out metrics are available." if result["heldout_metrics_available"] else "All frames were fitted; no held-out quality score is available."))


if __name__ == "__main__":
    main()
