#!/usr/bin/env python3
"""wbt_hash.py - helper for the write-blocker test toolkit.

Subcommands
  geometry  DEV                 size / sector sizes of a device or file
  hash      DEV [options]       SHA-256 of a whole device, a region, or baseline regions
  baseline  DEV [options]       build the reference baseline JSON (hash x2, cross-check, facts)
  compare   BASELINE RESULT     compare a hash run against a baseline (prints ID|STATUS|detail)
  pwrite    DEV [options]       attempt ONE write (used by the write-protection tests)
  firstdiff A B [options]       locate the first differing sectors between two devices/images
  jsonget   FILE KEY            print one top-level key from a JSON file

Reads on block devices use O_DIRECT so the host page cache cannot mask or fake a result.
Exit codes: 0 ok, 1 compare FAIL, 2 compare REVIEW / usage problem, 3 read error, 4 unstable baseline, 5 bad arguments.
"""
import argparse
import datetime
import errno
import hashlib
import json
import mmap
import os
import shlex
import shutil
import stat
import subprocess
import sys
import time

MIB = 1 << 20


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return r.returncode, (r.stdout + r.stderr).strip()


def is_blk(path):
    return stat.S_ISBLK(os.stat(path).st_mode)


def blockdev(path, opt):
    rc, out = run(["blockdev", opt, path])
    if rc == 0 and out.strip().isdigit():
        return int(out.strip())
    return None


def geometry(path):
    if is_blk(path):
        size = blockdev(path, "--getsize64")
        if size is None:
            fd = os.open(path, os.O_RDONLY)
            size = os.lseek(fd, 0, os.SEEK_END)
            os.close(fd)
        return {
            "size_bytes": size,
            "logical_sector": blockdev(path, "--getss") or 512,
            "physical_sector": blockdev(path, "--getpbsz") or 512,
        }
    return {"size_bytes": os.stat(path).st_size, "logical_sector": 512, "physical_sector": 512}


class ReadFail(Exception):
    def __init__(self, pos, cause):
        super().__init__(str(cause))
        self.pos = pos
        self.cause = cause


def open_read(path):
    direct = is_blk(path) and hasattr(os, "O_DIRECT")
    if direct:
        try:
            return os.open(path, os.O_RDONLY | os.O_DIRECT), True
        except OSError as e:
            if e.errno != errno.EINVAL:
                raise
    return os.open(path, os.O_RDONLY), False


def iter_blocks(fd, offset, length, direct, bs=MIB):
    buf = mmap.mmap(-1, bs)  # page-aligned, as O_DIRECT requires
    mv = memoryview(buf)
    pos, end = offset, offset + length
    while pos < end:
        want = min(bs, end - pos)
        got = 0
        while got < want:
            try:
                n = os.preadv(fd, [mv[got:want]], pos + got)
            except OSError as e:
                raise ReadFail(pos + got, e)
            if n == 0:
                raise ReadFail(pos + got, EOFError("unexpected end of device"))
            got += n
        if not direct:
            try:
                os.posix_fadvise(fd, pos, want, os.POSIX_FADV_DONTNEED)
            except OSError:
                pass
        yield pos, mv[:want]
        pos += want


def hash_region(fd, direct, off, ln):
    h = hashlib.sha256()
    for _, b in iter_blocks(fd, off, ln, direct):
        h.update(b)
    return h.hexdigest()


def full_hash(path, chunk_mib=1024):
    g = geometry(path)
    size, ss = g["size_bytes"], g["logical_sector"]
    fd, direct = open_read(path)
    chunk = chunk_mib * MIB
    h, ch, chunks = hashlib.sha256(), hashlib.sha256(), []
    t0 = time.time()
    out = dict(g)
    out.update({"device": path, "timestamp": now(), "o_direct": direct, "chunk_mib": chunk_mib})
    try:
        for pos, b in iter_blocks(fd, 0, size, direct):
            h.update(b)
            ch.update(b)
            end = pos + len(b)
            if end % chunk == 0 or end == size:
                chunks.append(ch.hexdigest())
                ch = hashlib.sha256()
        n = min(MIB, size)
        first = hash_region(fd, direct, 0, n)
        last = hash_region(fd, direct, size - n, n)
    except ReadFail as e:
        out["read_error"] = {"offset": e.pos, "lba": e.pos // ss, "error": str(e.cause)}
        return out
    finally:
        os.close(fd)
    el = time.time() - t0
    out.update({
        "elapsed_s": round(el, 2),
        "throughput_mib_s": round(size / MIB / el, 1) if el > 0 else None,
        "sha256": h.hexdigest(),
        "first_1mib_sha256": first,
        "last_1mib_sha256": last,
        "chunks": chunks,
    })
    return out


def hash_regions(path, regions, g):
    fd, direct = open_read(path)
    res = []
    try:
        for r in regions:
            item = {"name": r["name"], "offset": r["offset"], "length": r["length"]}
            if r["offset"] + r["length"] > g["size_bytes"]:
                item["error"] = "out of range for this device"
            else:
                try:
                    item["sha256"] = hash_region(fd, direct, r["offset"], r["length"])
                except ReadFail as e:
                    item["error"] = "read error at byte %d: %s" % (e.pos, e.cause)
            res.append(item)
    finally:
        os.close(fd)
    return res


META_CMDS = {
    "hdparm_identify": ["hdparm", "-I"],
    "hdparm_hpa": ["hdparm", "-N"],
    "smartctl_info": ["smartctl", "-i"],
    "smartctl_attrs": ["smartctl", "-A"],
    "nvme_id_ctrl": ["nvme", "id-ctrl"],
}


def meta(path):
    res, hpa = {}, None
    for k, c in META_CMDS.items():
        if not shutil.which(c[0]):
            res[k] = "missing"
            continue
        rc, out = run(c + [path])
        if rc is None:
            res[k] = "fail"
            continue
        ok = (rc & 3) == 0 if c[0] == "smartctl" else rc == 0
        res[k] = "ok" if ok else "fail"
        if k == "hdparm_hpa" and ok:
            for line in out.splitlines():
                if "max sectors" in line:
                    hpa = " ".join(line.split())
    return res, hpa


def badsector(path, lba, ss):
    fd, direct = open_read(path)
    try:
        for _ in iter_blocks(fd, lba * ss, ss, direct, bs=ss if direct else MIB):
            pass
        return {"lba": lba, "ok": True}
    except ReadFail as e:
        en = getattr(e.cause, "errno", None)
        return {"lba": lba, "ok": False, "errno": errno.errorcode.get(en, str(en)), "error": str(e.cause)}
    finally:
        os.close(fd)


def lsblk_facts(path):
    rc, out = run(["lsblk", "-dnb", "-P", "-o", "NAME,MODEL,SERIAL,VENDOR,REV,TRAN,SIZE,LOG-SEC,PHY-SEC,RO,ROTA", path])
    facts = {}
    if rc == 0 and out:
        try:
            for tok in shlex.split(out.splitlines()[0]):
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    facts[k.lower()] = v
        except ValueError:
            pass
    return facts


def boundary_regions(path, g):
    size, ss = g["size_bytes"], g["logical_sector"]
    regions = []
    seen = set()

    def add(name, off, ln):
        off -= off % ss
        if off < 0 or off + ln > size or off in seen:
            return
        seen.add(off)
        regions.append({"name": name, "offset": off, "length": ln})

    for name, b in (("lba28_128GiB", 2 ** 28 * 512), ("4GiB", 2 ** 32), ("lba32_limit", 2 ** 32 * ss), ("2TiB", 2 ** 41)):
        add(name, b - MIB, 2 * MIB)
    if is_blk(path):
        rc, out = run(["lsblk", "-nr", "-o", "NAME,TYPE", path])
        for line in (out.splitlines() if rc == 0 else []):
            parts = line.split()
            if len(parts) == 2 and parts[1] == "part":
                try:
                    st = int(open("/sys/class/block/%s/start" % parts[0]).read()) * 512
                    sz = int(open("/sys/class/block/%s/size" % parts[0]).read()) * 512
                except (OSError, ValueError):
                    continue
                add("%s_start" % parts[0], st, min(MIB, size - st))
                add("%s_end" % parts[0], st + sz - MIB, MIB)
    return regions


def sha256sum_cross(path):
    flags = "iflag=direct " if is_blk(path) else ""
    cmd = "set -o pipefail; dd if=%s bs=1M %sstatus=none | sha256sum" % (shlex.quote(path), flags)
    try:
        r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    except OSError:
        return None
    if r.returncode != 0 or not r.stdout.split():
        return None
    return r.stdout.split()[0]


def emit(out, a):
    if getattr(a, "out", None):
        with open(a.out, "w") as f:
            json.dump(out, f, indent=2)
    if getattr(a, "field", None):
        print(out.get(a.field, ""))
    elif not getattr(a, "out", None):
        print(json.dumps(out))


# ---------------------------------------------------------------- subcommands
def cmd_geometry(a):
    g = geometry(a.device)
    print(g[a.field] if a.field else json.dumps(g))
    return 0


def cmd_hash(a):
    path = a.device
    g = geometry(path)
    size, ss = g["size_bytes"], g["logical_sector"]
    if a.offset is not None or a.length is not None:
        off = a.offset or 0
        ln = a.length if a.length is not None else size - off
        ln = min(ln, size - off)
        if off % ss or ln % ss or ln < 0:
            print("ERROR: offset and length must be multiples of the logical sector size (%d)" % ss, file=sys.stderr)
            return 5
        fd, direct = open_read(path)
        try:
            digest = hash_region(fd, direct, off, ln)
        except ReadFail as e:
            out = {"device": path, "offset": off, "length": ln, "read_error": {"offset": e.pos, "error": str(e.cause)}}
            emit(out, a)
            return 3
        finally:
            os.close(fd)
        out = dict(g)
        out.update({"device": path, "offset": off, "length": ln, "sha256": digest, "o_direct": direct, "timestamp": now()})
        emit(out, a)
        return 0
    if a.quick:
        out = dict(g)
        out.update({"device": path, "timestamp": now(), "quick": True})
    else:
        out = full_hash(path, a.chunk_mib)
    if "read_error" in out:
        emit(out, a)
        return 3
    if a.regions_from:
        base = json.load(open(a.regions_from))
        out["regions"] = hash_regions(path, base.get("regions", []), g)
    if a.with_meta:
        m, h = meta(path)
        out["meta"], out["hpa"] = m, h
    if a.badsector_lba is not None:
        out["badsector"] = badsector(path, a.badsector_lba, ss)
    emit(out, a)
    return 0


def cmd_baseline(a):
    path = a.device
    g = geometry(path)
    runs = []
    for i in range(a.python_runs):
        r = full_hash(path, a.chunk_mib)
        if "read_error" in r:
            print("ERROR: read error during baseline run %d: %s" % (i + 1, r["read_error"]), file=sys.stderr)
            return 3
        runs.append(r)
    if len({r["sha256"] for r in runs}) != 1:
        print("ERROR: the reference drive hashed differently between runs - it is not stable; do not use it", file=sys.stderr)
        return 4
    base = runs[0]
    cross = None if a.no_cross_check else sha256sum_cross(path)
    if cross is not None and cross != base["sha256"]:
        print("ERROR: sha256sum cross-check disagrees with wbt_hash (%s vs %s)" % (cross, base["sha256"]), file=sys.stderr)
        return 4
    base["type"] = "baseline"
    base["python_runs"] = a.python_runs
    base["cross_check_sha256"] = cross
    base["cross_check"] = "matched" if cross else "unavailable"
    base["facts"] = lsblk_facts(path)
    base["meta"], base["hpa"] = meta(path)
    regs = boundary_regions(path, g)
    fd, direct = open_read(path)
    try:
        for r in regs:
            r["sha256"] = hash_region(fd, direct, r["offset"], r["length"])
    except ReadFail as e:
        print("ERROR: read error while hashing boundary regions at byte %d" % e.pos, file=sys.stderr)
        return 3
    finally:
        os.close(fd)
    base["regions"] = regs
    if a.badsector_lba is not None:
        base["badsector"] = badsector(path, a.badsector_lba, g["logical_sector"])
    for kv in a.set or []:
        k, _, v = kv.partition("=")
        base.setdefault("notes", {})[k] = v
    with open(a.out, "w") as f:
        json.dump(base, f, indent=2)
    print("baseline written: %s (sha256 %s, cross-check %s)" % (a.out, base["sha256"], base["cross_check"]))
    return 0


def cmd_compare(a):
    base = json.load(open(a.baseline))
    res = json.load(open(a.result))
    lines = []

    def add(i, st, msg):
        lines.append((i, st, msg))

    if "read_error" in res:
        e = res["read_error"]
        add("P2-01", "FAIL", "read error through this path at LBA %s: %s" % (e.get("lba"), e.get("error")))
    # geometry
    if res.get("size_bytes") != base.get("size_bytes"):
        add("P2-04", "FAIL", "capacity differs: baseline %s bytes, this path %s bytes" % (base.get("size_bytes"), res.get("size_bytes")))
    else:
        d = [k for k in ("logical_sector", "physical_sector") if res.get(k) != base.get(k)]
        if d:
            add("P2-04", "REVIEW", "capacity matches but %s differ (baseline %s/%s, this path %s/%s) - explain and document" % (
                ", ".join(d), base.get("logical_sector"), base.get("physical_sector"), res.get("logical_sector"), res.get("physical_sector")))
        else:
            add("P2-04", "PASS", "capacity %s bytes and sector sizes %s/%s match baseline" % (res.get("size_bytes"), res.get("logical_sector"), res.get("physical_sector")))
    if "sha256" in res:
        if res["sha256"] == base.get("sha256"):
            add("P2-01", "PASS", "full-drive SHA-256 matches baseline")
        else:
            add("P2-01", "FAIL", "full-drive SHA-256 differs from baseline")
        for key, label in (("first_1mib_sha256", "first 1 MiB"), ("last_1mib_sha256", "last 1 MiB")):
            add("P2-02", "PASS" if res.get(key) == base.get(key) else "FAIL", "%s %s baseline" % (label, "matches" if res.get(key) == base.get(key) else "differs from"))
        if res.get("chunk_mib") == base.get("chunk_mib") and res.get("chunks") is not None:
            bad = [i for i, (x, y) in enumerate(zip(base["chunks"], res["chunks"])) if x != y]
            if len(res["chunks"]) != len(base["chunks"]):
                add("P2-03", "FAIL", "chunk count differs (%d vs %d)" % (len(res["chunks"]), len(base["chunks"])))
            elif bad:
                cm = base["chunk_mib"]
                add("P2-03", "FAIL", "%d chunk(s) differ; first at byte offset %d (chunk %d, %d MiB chunks)" % (len(bad), bad[0] * cm * MIB, bad[0], cm))
            else:
                add("P2-03", "PASS", "all %d chunk hashes match" % len(res["chunks"]))
    if res.get("regions") is not None:
        bmap = {r["name"]: r for r in base.get("regions", [])}
        fails = [r["name"] for r in res["regions"] if "sha256" in r and r["name"] in bmap and r["sha256"] != bmap[r["name"]].get("sha256")]
        errs = [r["name"] for r in res["regions"] if "error" in r]
        if fails or errs:
            add("P2-03", "FAIL", "boundary/partition regions differ or unreadable: %s" % ", ".join(fails + errs))
        else:
            add("P2-03", "PASS", "%d boundary/partition regions match baseline" % len(res["regions"]))
    if "badsector" in base and "badsector" in res:
        b, r = base["badsector"], res["badsector"]
        if b.get("ok") is False and r.get("ok") is True:
            add("P2-05", "FAIL", "LBA %s is unreadable on the direct path but returned data through this path (fabricated data)" % b.get("lba"))
        elif b.get("ok") is False:
            add("P2-05", "PASS" if b.get("errno") == r.get("errno") else "REVIEW", "unreadable sector reported as error (%s; baseline %s)" % (r.get("errno"), b.get("errno")))
        else:
            add("P2-05", "PASS" if r.get("ok") else "FAIL", "sector %s readable" % b.get("lba"))
    if "meta" in res and "meta" in base:
        miss = [k for k, v in base["meta"].items() if v == "ok" and res["meta"].get(k) != "ok"]
        if miss:
            add("P2-06", "REVIEW", "commands that work on the direct path but not here: %s" % ", ".join(miss))
        else:
            add("P2-06", "PASS", "metadata commands that work on the direct path also work here")
        if base.get("hpa"):
            if res.get("hpa") is None:
                add("P2-07", "REVIEW", "HPA status not visible through this path (baseline: %s)" % base["hpa"])
            elif res["hpa"] == base["hpa"]:
                add("P2-07", "PASS", "HPA status matches baseline (%s)" % res["hpa"])
            else:
                add("P2-07", "REVIEW", "HPA status differs: baseline '%s' vs here '%s'" % (base["hpa"], res["hpa"]))
    bt, rt = base.get("throughput_mib_s"), res.get("throughput_mib_s")
    if bt and rt:
        add("P2-08", "REVIEW" if rt < 0.5 * bt else "PASS", "sustained read %s MiB/s vs baseline %s MiB/s" % (rt, bt))
    for i, st, msg in lines:
        print("%s|%s|%s" % (i, st, msg))
    stat_set = {st for _, st, _ in lines}
    return 1 if "FAIL" in stat_set else (2 if "REVIEW" in stat_set else 0)


def cmd_pwrite(a):
    g = geometry(a.device)
    ss = g["logical_sector"]
    off, ln = a.offset, a.length
    if off % ss or ln % ss or ln <= 0:
        print("ERROR: offset/length must be multiples of the logical sector size (%d)" % ss, file=sys.stderr)
        return 5
    if off + ln > g["size_bytes"]:
        print("ERROR: write range beyond end of device", file=sys.stderr)
        return 5
    pat = bytes([int(a.pattern, 16)]) * ln
    direct = (not a.buffered) and is_blk(a.device) and hasattr(os, "O_DIRECT")
    rec = {"timestamp": now(), "device": a.device, "offset": off, "length": ln,
           "mode": "O_DIRECT" if direct else "buffered", "tag": a.tag}
    stage = "open"
    fd = None
    try:
        fd = os.open(a.device, os.O_WRONLY | (os.O_DIRECT if direct else 0))
        stage = "write"
        buf = mmap.mmap(-1, ln)
        buf.write(pat)
        n = os.pwritev(fd, [memoryview(buf)], off)
        rec["bytes_written"] = n
        rec["write_ok"] = n == ln
        stage = "fsync"
        os.fsync(fd)
        rec["fsync_ok"] = True
    except OSError as e:
        if stage == "fsync":
            rec["fsync_ok"] = False
        else:
            rec["write_ok"] = False
        rec.update({"stage": stage, "errno": errno.errorcode.get(e.errno, str(e.errno)), "error": os.strerror(e.errno or 0)})
    finally:
        if fd is not None:
            os.close(fd)
    shows = "n/a"
    if a.readback and rec.get("write_ok"):
        try:
            rfd, rdirect = open_read(a.device)
            try:
                data = b"".join(bytes(b) for _, b in iter_blocks(rfd, off, ln, rdirect))
            finally:
                os.close(rfd)
            shows = str(data == pat)
        except ReadFail as e:
            shows = "read-error(%s)" % e.cause
    rec["readback_shows_new_data"] = shows
    if a.json_out:
        with open(a.json_out, "a") as f:
            f.write(json.dumps(rec) + "\n")
    print("write_ok=%s stage=%s errno=%s readback_shows_new_data=%s" % (
        rec.get("write_ok", False), rec.get("stage", "done"), rec.get("errno", "-"), shows))
    return 0


def cmd_firstdiff(a):
    ga, gb = geometry(a.a), geometry(a.b)
    ss = gb["logical_sector"]
    size = min(ga["size_bytes"], gb["size_bytes"])
    if ga["size_bytes"] != gb["size_bytes"]:
        print("NOTE: sizes differ (%d vs %d); comparing the first %d bytes" % (ga["size_bytes"], gb["size_bytes"], size))
    fa, da = open_read(a.a)
    fb, db = open_read(a.b)
    found, count, prev_b = [], 0, None
    zero = bytes(ss)
    try:
        for (pa, ba), (pb, bb) in zip(iter_blocks(fa, 0, size, da), iter_blocks(fb, 0, size, db)):
            if bytes(ba) == bytes(bb):
                prev_b = bytes(bb[-ss:])
                continue
            for s in range(0, len(ba), ss):
                sa, sb = bytes(ba[s:s + ss]), bytes(bb[s:s + ss])
                if sa != sb:
                    count += 1
                    if len(found) < a.limit:
                        kind = "zero-filled" if sb == zero else ("repeat of previous sector" if sb == prev_b else "other")
                        found.append((pa // ss + s // ss, kind))
                prev_b = sb
    except ReadFail as e:
        print("read error at byte %d: %s" % (e.pos, e.cause))
        return 3
    finally:
        os.close(fa)
        os.close(fb)
    if not count:
        print("no differences in the first %d bytes" % size)
        return 0
    print("%d differing sector(s). First %d:" % (count, len(found)))
    for lba, kind in found:
        print("  LBA %d (byte %d): %s" % (lba, lba * ss, kind))
    return 1


def cmd_jsonget(a):
    v = json.load(open(a.file))
    for k in a.key.split("."):
        v = v.get(k, "") if isinstance(v, dict) else ""
    print(v)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)

    g = sp.add_parser("geometry")
    g.add_argument("device")
    g.add_argument("--field")
    g.set_defaults(fn=cmd_geometry)

    h = sp.add_parser("hash")
    h.add_argument("device")
    h.add_argument("--chunk-mib", type=int, default=1024)
    h.add_argument("--offset", type=int)
    h.add_argument("--length", type=int)
    h.add_argument("--regions-from")
    h.add_argument("--with-meta", action="store_true")
    h.add_argument("--badsector-lba", type=int)
    h.add_argument("--quick", action="store_true", help="skip the full-drive hash (geometry, regions, metadata only)")
    h.add_argument("--out")
    h.add_argument("--field")
    h.set_defaults(fn=cmd_hash)

    b = sp.add_parser("baseline")
    b.add_argument("device")
    b.add_argument("--out", required=True)
    b.add_argument("--chunk-mib", type=int, default=1024)
    b.add_argument("--python-runs", type=int, default=2)
    b.add_argument("--no-cross-check", action="store_true")
    b.add_argument("--badsector-lba", type=int)
    b.add_argument("--set", action="append", help="key=value note stored in the baseline")
    b.set_defaults(fn=cmd_baseline)

    c = sp.add_parser("compare")
    c.add_argument("baseline")
    c.add_argument("result")
    c.set_defaults(fn=cmd_compare)

    w = sp.add_parser("pwrite")
    w.add_argument("device")
    w.add_argument("--offset", type=int, required=True)
    w.add_argument("--length", type=int, required=True)
    w.add_argument("--pattern", default="A5", help="hex byte to write (default A5)")
    w.add_argument("--buffered", action="store_true")
    w.add_argument("--readback", action="store_true")
    w.add_argument("--json-out")
    w.add_argument("--tag", default="")
    w.set_defaults(fn=cmd_pwrite)

    d = sp.add_parser("firstdiff")
    d.add_argument("a", help="known-good copy (for example the baseline image)")
    d.add_argument("b", help="device or image to check")
    d.add_argument("--limit", type=int, default=20)
    d.set_defaults(fn=cmd_firstdiff)

    j = sp.add_parser("jsonget")
    j.add_argument("file")
    j.add_argument("key")
    j.set_defaults(fn=cmd_jsonget)

    a = p.parse_args()
    try:
        return a.fn(a)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
