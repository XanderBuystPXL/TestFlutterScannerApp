"""Explicit-role scene adapter for the existing research trainer; no SfM split guessing."""
from collections import OrderedDict
from pathlib import Path
import numpy as np
from PIL import Image

from capture_pipeline import require, verify_dataset


def scene_arrays(root, factor=1):
    require(isinstance(factor, int) and factor >= 1, "factor must be an integer >= 1.")
    root = Path(root)
    config = verify_dataset(root)
    rows = config["frames"]
    train = [i for i, f in enumerate(rows) if f["role"] == "train"]
    val = [i for i, f in enumerate(rows) if f["role"] == "validation"]
    all_frames = config.get("dataset_mode") == "all-frames"
    require(len(train) >= 20 and (len(val) == 0 if all_frames else len(val) >= 10) and len(train)+len(val) == len(rows), "Dataset roles differ from the declared fitting/evaluation mode.")
    normalization = config["normalization"]
    origin, scale = np.array(normalization["origin"]), normalization["scale"]
    worlds = np.array([f["camera_to_world_cv_metres"] for f in rows])
    worlds[:, :3, 3] = (worlds[:, :3, 3] - origin) * scale
    sizes, Ks = [], []
    for f in rows:
        ow, oh = f["size"]
        w, h = max(1, ow//factor), max(1, oh//factor)
        K = np.array(f["K"])
        K[0] *= w/ow
        K[1] *= h/oh
        Ks.append(K)
        sizes.append((w, h, ow, oh))
    with np.load(root / "points.npz", allow_pickle=False) as data:
        points, colors = data["points"].copy(), data["colors"].copy()
    require(points.shape == colors.shape and points.ndim == 2 and points.shape[1] == 3 and
            len(points) >= 100 and np.isfinite(points).all(), "Invalid sensor initialization.")
    return config, train, val, worlds, sizes, Ks, points, colors


class CaptureScene:
    def __init__(self, root, factor=1, test_every=8, cache_mb=512):
        import torch
        self.root = Path(root)
        config, self.train, self.val, self.worlds, self.sizes, Ks, self.points, self.colors = scene_arrays(root, factor)
        self.names = [f["name"] for f in config["frames"]]
        self.normalization = config["normalization"]
        self.validation_protocol = config["validation_protocol"]
        self.origin = np.array(self.normalization["origin"])
        self.radius = 1 / self.normalization["scale"]
        self.Ks = [torch.tensor(K, dtype=torch.float32) for K in Ks]
        self.views = [torch.tensor(np.linalg.inv(w), dtype=torch.float32) for w in self.worlds]
        self.cache, self.cache_bytes, self.cache_limit = OrderedDict(), 0, cache_mb*1024*1024

    def image(self, index):
        import torch
        if index in self.cache:
            self.cache.move_to_end(index)
            return self.cache[index]
        w, h, ow, oh = self.sizes[index]
        with Image.open(self.root / "images" / self.names[index]) as im:
            require(im.size == (ow, oh), "Image dimensions changed.")
            im = im.convert("RGB")
            if im.size != (w, h):
                im = im.resize((w, h), Image.Resampling.LANCZOS)
            tensor = torch.from_numpy(np.array(im).copy())
        size = tensor.numel()*tensor.element_size()
        while self.cache and self.cache_bytes+size > self.cache_limit:
            _, old = self.cache.popitem(last=False)
            self.cache_bytes -= old.numel()*old.element_size()
        if size <= self.cache_limit:
            self.cache[index] = tensor
            self.cache_bytes += size
        return tensor

    def metadata(self):
        world = self.worlds[self.train[0]]
        # ARKit gravity supplies world up; normalization translates/scales only.
        return {"normalization": self.normalization, "camera_position": world[:3, 3].tolist(),
                "camera_target": (world[:3, 3]+world[:3, 2]).tolist(), "camera_up": [0, 1, 0],
                "train_views": len(self.train), "validation_views": len(self.val),
                "validation_protocol": self.validation_protocol,
                "splits": {"train": [self.names[i] for i in self.train], "validation": [self.names[i] for i in self.val]},
                "views": [{"name": n, "camera_to_world": w.tolist(),
                           "vertical_fov_degrees": float(np.degrees(2*np.arctan(self.sizes[i][1]/(2*self.Ks[i][1, 1].item()))))}
                          for i, (n, w) in enumerate(zip(self.names, self.worlds))]}
