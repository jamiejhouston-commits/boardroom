from __future__ import annotations

from pathlib import Path
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont

DRAWIO = Path(__file__).with_name("boardroom-architecture.drawio")
PNG = Path(__file__).with_name("boardroom-architecture-preview.png")

root = ET.parse(DRAWIO).getroot()
mx_root = root.find(".//root")
assert mx_root is not None

vertices = {}
edges = []
texts = []
for cell in mx_root.findall("mxCell"):
    cid = cell.attrib.get("id")
    geom = cell.find("mxGeometry")
    value = cell.attrib.get("value", "")
    style = cell.attrib.get("style", "")
    if cell.attrib.get("vertex") == "1" and geom is not None:
        x = float(geom.attrib.get("x", 0)); y = float(geom.attrib.get("y", 0))
        w = float(geom.attrib.get("width", 0)); h = float(geom.attrib.get("height", 0))
        fill = "#ffffff"; stroke = "#333333"; font = "#111827"
        for part in style.split(";"):
            if part.startswith("fillColor="): fill = part.split("=",1)[1]
            if part.startswith("strokeColor="): stroke = part.split("=",1)[1]
            if part.startswith("fontColor="): font = part.split("=",1)[1]
        item = dict(id=cid, value=value, x=x, y=y, w=w, h=h, fill=fill, stroke=stroke, font=font, style=style)
        if style.startswith("text;"):
            texts.append(item)
        else:
            vertices[cid] = item
    elif cell.attrib.get("edge") == "1":
        edges.append(dict(source=cell.attrib.get("source"), target=cell.attrib.get("target"), value=value, style=style))

W,H = 1280,1120
img = Image.new("RGB", (W,H), "#f8fafc")
d = ImageDraw.Draw(img)

def font(size=14,bold=False):
    candidates = [
        "C:/Windows/Fonts/segoeuib.ttf" if bold else "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf",
    ]
    for p in candidates:
        if Path(p).exists(): return ImageFont.truetype(p,size)
    return ImageFont.load_default()

f12=font(12); f13=font(13); f16=font(16, True); f22=font(22, True)

def center(v): return (v["x"]+v["w"]/2, v["y"]+v["h"]/2)

def draw_arrow(a,b,color="#6b7280"):
    ax,ay=a; bx,by=b
    # elbow routing for readability
    midx=(ax+bx)/2
    pts=[(ax,ay),(midx,ay),(midx,by),(bx,by)]
    d.line(pts, fill=color, width=2)
    # simple arrowhead
    import math
    ang=math.atan2(by-pts[-2][1], bx-pts[-2][0])
    size=8
    left=(bx-size*math.cos(ang-0.5), by-size*math.sin(ang-0.5))
    right=(bx-size*math.cos(ang+0.5), by-size*math.sin(ang+0.5))
    d.polygon([(bx,by), left, right], fill=color)

# edges first
for e in edges:
    s=vertices.get(e["source"]); t=vertices.get(e["target"])
    if s and t: draw_arrow(center(s), center(t), "#64748b")

# boxes
for v in vertices.values():
    x,y,w,h = int(v["x"]), int(v["y"]), int(v["w"]), int(v["h"])
    d.rounded_rectangle([x,y,x+w,y+h], radius=12, fill=v["fill"], outline=v["stroke"], width=2)
    lines = v["value"].replace("<br/>", "\n").splitlines()
    yy=y+10
    for i,line in enumerate(lines[:5]):
        ft=f13 if i else f13
        d.text((x+12,yy), line, fill=v["font"], font=ft)
        yy += 17

# text labels
for t in texts:
    ft = f22 if "fontSize=22" in t["style"] else (f16 if "fontSize=18" in t["style"] else f12)
    d.multiline_text((int(t["x"]), int(t["y"])), t["value"], fill=t["font"], font=ft, spacing=4)

PNG.parent.mkdir(parents=True, exist_ok=True)
img.save(PNG)
print(PNG)
print(PNG.stat().st_size)
