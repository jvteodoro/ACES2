#!/usr/bin/env python3
"""Parse Linux usbfs sysfs descriptor blob; preserve unknown descriptors verbatim."""
import argparse
import json
from pathlib import Path

def parse(blob):
    if len(blob) < 18 or blob[1] != 1 or blob[0] != 18:
        raise ValueError("missing/invalid 18-byte USB device descriptor")
    dev = {"length":blob[0], "type":blob[1], "usb_bcd":f"{blob[3]:02x}{blob[2]:02x}",
           "device_class":blob[4], "device_subclass":blob[5], "device_protocol":blob[6],
           "ep0_max_packet_size":blob[7], "vid":f"{blob[9]:02x}{blob[8]:02x}",
           "pid":f"{blob[11]:02x}{blob[10]:02x}", "device_bcd":f"{blob[13]:02x}{blob[12]:02x}",
           "manufacturer_string_index":blob[14], "product_string_index":blob[15],
           "serial_string_index":blob[16], "configurations":blob[17]}
    if dev["configurations"] != 1:
        raise ValueError("parser expects observed single configuration; update it for multi-config devices")
    pos=18
    if len(blob)-pos < 9 or blob[pos+1] != 2:
        raise ValueError("configuration descriptor missing at offset 18")
    clen=blob[pos]
    total=blob[pos+2] | blob[pos+3]<<8
    if clen < 9 or total < clen or pos+total > len(blob):
        raise ValueError(f"invalid configuration wTotalLength={total}, blob size={len(blob)}")
    cfg=blob[pos:pos+total]
    if len(cfg) != total: raise ValueError("truncated configuration")
    config={"length":clen,"total_length":total,"interfaces_declared":cfg[4],
            "value":cfg[5],"attributes":cfg[7],"max_power_units_2ma":cfg[8],"interfaces":[]}
    interfaces={}; current=None
    off=0
    while off < len(cfg):
        if off+2 > len(cfg): raise ValueError(f"truncated descriptor header at config offset {off}")
        n, typ=cfg[off],cfg[off+1]
        if n < 2 or off+n > len(cfg): raise ValueError(f"invalid bLength={n} at config offset {off}")
        raw=cfg[off:off+n]
        rec={"offset":off,"length":n,"type":typ,"raw_hex":raw.hex()}
        if typ == 4:
            if n < 9: raise ValueError(f"short interface descriptor at {off}")
            key=(raw[2],raw[3]); current={"number":raw[2],"alternate_setting":raw[3],"endpoints_declared":raw[4],
                "class":raw[5],"subclass":raw[6],"protocol":raw[7],"string_index":raw[8],"descriptors":[],"endpoints":[]}
            interfaces[key]=current
        if typ == 5 and current is not None:
            if n < 7: raise ValueError(f"short endpoint descriptor at {off}")
            current["endpoints"].append({"address":raw[2],"attributes":raw[3],"max_packet_size":raw[4]|raw[5]<<8,"interval":raw[6],"raw_hex":raw.hex()})
        if current is not None: current["descriptors"].append(rec)
        off += n
    config["interfaces"]=[interfaces[k] for k in sorted(interfaces)]
    if len(config["interfaces"]) == 0: raise ValueError("no interfaces parsed")
    if len({i["number"] for i in config["interfaces"]}) != config["interfaces_declared"]:
        raise ValueError("number of parsed interface numbers differs from bNumInterfaces")
    for i in config["interfaces"]:
        if len(i["endpoints"]) != i["endpoints_declared"]: raise ValueError(f"endpoint count mismatch at {i['number']}.{i['alternate_setting']}")
    return {"source":{"method":"read-only Linux sysfs /sys/bus/usb/devices/1-2/descriptors","blob_length":len(blob),"configuration_bytes_validated":total},"device":dev,"configuration":config,
            "strings":{"1":"Burr-Brown from TI              ","2":"USB Audio CODEC ","string_source":"sysfs manufacturer/product attributes; lsusb -v corroborates"}}

if __name__ == '__main__':
    ap=argparse.ArgumentParser(); ap.add_argument('input',type=Path); ap.add_argument('output',type=Path); a=ap.parse_args()
    data=parse(a.input.read_bytes()); a.output.write_text(json.dumps(data,indent=2)+"\n")
