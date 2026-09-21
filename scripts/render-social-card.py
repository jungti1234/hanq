#!/usr/bin/env python3
"""Generate the site's social preview using the existing HanQ logo (Pillow, macOS)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SCALE = 2
canvas = Image.new('RGB', (1200*SCALE, 630*SCALE), '#f7f8fa')
draw = ImageDraw.Draw(canvas)
font_path = '/System/Library/Fonts/AppleSDGothicNeo.ttc'

def text(x, y, value, size, color, bold=False):
    font = ImageFont.truetype(font_path, size*SCALE, index=6 if bold else 0)
    draw.text((x*SCALE, y*SCALE), value, font=font, fill=color, anchor='lt')

text(78, 68, '한Q', 32, '#1c2330', True)
text(78, 184, 'Mac의 한글 생활,', 64, '#1c2330', True)
text(78, 268, '한큐에.', 80, '#1764ed', True)
text(81, 391, '한영 전환부터 한자 입력까지.', 29, '#626b79')
text(81, 525, 'Apple Silicon · macOS 13 이상 · 무료 사용', 21, '#626b79')
logo = Image.open(ROOT / 'Resources/HanQ-Logo.png').convert('RGBA')
logo.thumbnail((420*SCALE, 360*SCALE), Image.Resampling.LANCZOS)
canvas.paste(logo, (710*SCALE, 177*SCALE), logo)
canvas.resize((1200,630), Image.Resampling.LANCZOS).save(ROOT / 'updates/site/assets/hanq-social-v1.png', optimize=True)
