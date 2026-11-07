#!/usr/bin/env python3
"""Draw the offline installer surface and write Finder metadata on the mounted image.

Requires Pillow, ds_store 1.3.3 and mac_alias 2.2.3. Never touches signed app contents.
"""
import argparse
import html
import json
import pathlib
import subprocess

WIDTH, HEIGHT = 640, 440
POSITIONS = {"LimLink.app": (162, 222), "Applications": (478, 222)}


def draw_background(channel, destination):
    from PIL import Image, ImageDraw, ImageFont
    destination = pathlib.Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    cn = channel == "Direct"
    fonts = pathlib.Path("/System/Library/Fonts")
    def draw(scale, path):
        image = Image.new("RGB", (WIDTH * scale, HEIGHT * scale), "#f8f8f6")
        ink = ImageDraw.Draw(image)
        def font(size, bold=False, cjk=False):
            return ImageFont.truetype(str(fonts / ("Hiragino Sans GB.ttc" if cjk else "HelveticaNeue.ttc")), round(size * scale), index=(2 if bold and cjk else 0))
        def text(x, y, message, size, fill="#151515", bold=False, cjk=False):
            ink.text((x * scale, y * scale), message, font=font(size, bold, cjk), fill=fill)
        def line(points, fill, width):
            ink.line([(x * scale, y * scale) for x, y in points], fill=fill, width=round(width * scale), joint="curve")
        ink.ellipse((36*scale, 35*scale, 60*scale, 59*scale), outline="#151515", width=3*scale)
        text(72, 29, "LimLink", 30, bold=True)
        text(504, 42, "macOS", 11, "#6a6a68")
        text(36, 89, "两步完成安装" if cn else "Install in two steps.", 25, bold=True, cjk=cn)
        text(36, 128, "先拷贝，再打开。  Copy first. Then open." if cn else "Copy first. Then open LimLink from Applications.", 12, "#777775", cjk=cn)
        for x in (162, 478):
            ink.rounded_rectangle(((x-76)*scale, 165*scale, (x+76)*scale, 294*scale), radius=18*scale, fill="#ffffff", outline="#e9e9e5", width=scale)
        line([(283, 222), (353, 222)], "#1e1e1e", 4)
        line([(338, 207), (353, 222), (338, 237)], "#1e1e1e", 4)
        line([(36, 319), (604, 319)], "#dfdfdc", 1)
        if cn:
            text(36, 338, "01", 11, "#82827e")
            text(66, 333, "拖入应用程序", 16, bold=True, cjk=True)
            text(66, 361, "将 LimLink 拖到右侧文件夹。", 12, "#70706c", cjk=True)
            text(348, 338, "02", 11, "#82827e")
            text(378, 333, "打开 LimLink", 16, bold=True, cjk=True)
            text(378, 361, "拷贝完成后，从应用程序打开。", 12, "#70706c", cjk=True)
            text(36, 411, "完成后推出此磁盘。  Eject this disk when finished.", 10, "#8a8a85", cjk=True)
        else:
            text(36, 338, "01", 11, "#82827e")
            text(66, 333, "Drag to Applications", 16, bold=True)
            text(66, 361, "Move LimLink into the folder above.", 12, "#70706c")
            text(348, 338, "02", 11, "#82827e")
            text(378, 333, "Open LimLink", 16, bold=True)
            text(378, 361, "Open it from Applications after copying.", 11, "#70706c")
            text(36, 411, "Eject this disk when you’re done.", 10, "#8a8a85")
        image.save(path, dpi=(72 * scale, 72 * scale))
    standard = destination.with_suffix(".png")
    retina = destination.with_name(destination.stem + "@2x.png")
    draw(1, standard); draw(2, retina)
    subprocess.run(["/usr/bin/tiffutil", "-cathidpicheck", str(standard), str(retina), "-out", str(destination)], check=True)
    return {"width": WIDTH, "height": HEIGHT, "channel": channel, "background": str(destination), "icons": POSITIONS}


def write_layout(mount):
    from ds_store import DSStore
    from mac_alias import Alias
    mount = pathlib.Path(mount).resolve()
    if not mount.is_mount():
        raise ValueError("Finder background alias must be created on the mounted image, not a host staging folder")
    background = mount / ".background" / "installer.tiff"
    if not background.is_file() or not (mount / "LimLink.app").is_dir() or not (mount / "Applications").is_symlink():
        raise ValueError("Expected image-local background and the two installation icons")
    alias = Alias.for_file(str(background)).to_bytes()
    with DSStore.open(str(mount / ".DS_Store"), "w+") as store:
        store["."]["bwsp"] = {"ShowStatusBar": False, "ShowToolbar": False, "ShowSidebar": False,
            "ShowPathbar": False, "ShowTabView": False, "ContainerShowSidebar": False,
            "WindowBounds": "{{180, 150}, {640, 468}}", "SidebarWidth": 0}
        store["."]["icvp"] = {"viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": alias,
            "backgroundColorRed": 0.9725, "backgroundColorGreen": 0.9725, "backgroundColorBlue": 0.9647,
            "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "arrangeBy": "none",
            "showIconPreview": True, "showItemInfo": False, "labelOnBottom": True,
            "textSize": 13.0, "iconSize": 92.0, "scrollPositionX": 0.0, "scrollPositionY": 0.0}
        store["."]["vSrn"] = ("long", 1)
        store["."]["icvl"] = ("type", b"icnv")
        for name, position in POSITIONS.items():
            store[name]["Iloc"] = position
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        assert store["."]["bwsp"]["ShowToolbar"] is False
        assert store["."]["icvp"]["iconSize"] == 92.0
        assert store["LimLink.app"]["Iloc"] == (162, 222)
        assert store["Applications"]["Iloc"] == (478, 222)
        decoded = Alias.from_bytes(store["."]["icvp"]["backgroundImageAlias"])
        assert decoded.target.filename == "installer.tiff"
    return {"mount": str(mount), "backgroundAliasCreatedOnMountedImage": True, "icons": POSITIONS}


GUIDES = [
    ("zh-Hans", "简体中文", "安装 LimLink", "打开磁盘映像，将 LimLink 图标拖入右侧“应用程序”文件夹。", "拷贝完成后，从“应用程序”打开 LimLink，然后推出安装磁盘。", "如已安装 LimLink，请先退出旧版本，再按系统提示替换。文件与设置保留在原位置。"),
    ("zh-Hant", "繁體中文", "安裝 LimLink", "開啟磁碟映像，將 LimLink 圖示拖入右側的「應用程式」資料夾。", "拷貝完成後，從「應用程式」開啟 LimLink，再退出安裝磁碟。", "若已安裝 LimLink，請先結束舊版本，再依系統提示取代。檔案與設定保留在原位置。"),
    ("en", "English", "Install LimLink", "Open the disk image and drag LimLink into the Applications folder on the right.", "When copying is complete, open LimLink from Applications, then eject the installer disk.", "If LimLink is already installed, quit the old version first, then follow the system’s replacement prompt. Files and settings stay in their existing locations."),
    ("ja", "日本語", "LimLink のインストール", "ディスクイメージを開き、LimLink を右側の「アプリケーション」フォルダへドラッグします。", "コピー後、「アプリケーション」から LimLink を開き、インストールディスクを取り出します。", "すでにインストールされている場合は、古いバージョンを終了してから、システムの案内に従って置き換えてください。ファイルと設定は元の場所に残ります。"),
    ("ko", "한국어", "LimLink 설치", "디스크 이미지를 열고 LimLink 아이콘을 오른쪽 응용 프로그램 폴더로 드래그하세요.", "복사가 끝나면 응용 프로그램에서 LimLink를 열고 설치 디스크를 추출하세요.", "이미 설치되어 있다면 이전 버전을 종료한 뒤 시스템 안내에 따라 교체하세요. 파일과 설정은 기존 위치에 유지됩니다."),
    ("fr", "Français", "Installer LimLink", "Ouvrez l’image disque et faites glisser LimLink dans le dossier Applications à droite.", "Une fois la copie terminée, ouvrez LimLink depuis Applications, puis éjectez le disque d’installation.", "Si LimLink est déjà installé, quittez l’ancienne version avant de suivre la demande de remplacement du système. Vos fichiers et réglages restent à leur emplacement actuel."),
    ("de", "Deutsch", "LimLink installieren", "Öffne das Festplattenimage und ziehe LimLink in den Ordner Programme auf der rechten Seite.", "Öffne LimLink nach dem Kopieren aus Programme und wirf anschließend das Installationsvolume aus.", "Wenn LimLink bereits installiert ist, beende zuerst die alte Version und folge dem Ersetzen-Dialog des Systems. Dateien und Einstellungen bleiben an ihrem bisherigen Ort."),
    ("es", "Español", "Instalar LimLink", "Abre la imagen de disco y arrastra LimLink a la carpeta Aplicaciones de la derecha.", "Cuando termine la copia, abre LimLink desde Aplicaciones y expulsa el disco de instalación.", "Si LimLink ya está instalado, cierra la versión anterior y sigue la indicación del sistema para reemplazarla. Los archivos y ajustes permanecen en su ubicación actual."),
    ("it", "Italiano", "Installare LimLink", "Apri l’immagine disco e trascina LimLink nella cartella Applicazioni a destra.", "Al termine della copia, apri LimLink da Applicazioni, poi espelli il disco di installazione.", "Se LimLink è già installato, chiudi la versione precedente e segui la richiesta di sostituzione del sistema. File e impostazioni rimangono nelle posizioni esistenti."),
]


def write_guide(destination):
    sections = []
    for tag, label, title, first, second, update in GUIDES:
        sections.append(f'<section id="{tag}" lang="{tag}"><p class="language">{html.escape(label)}</p><h2>{html.escape(title)}</h2><ol><li>{html.escape(first)}</li><li>{html.escape(second)}</li></ol><p class="note">{html.escape(update)}</p></section>')
    nav = " · ".join(f'<a href="#{tag}">{html.escape(label)}</a>' for tag, label, *_ in GUIDES)
    page = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>LimLink · Installation</title><style>body{margin:0;background:#f8f8f6;color:#171717;font:16px/1.7 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:760px;margin:auto;padding:48px 28px}h1{font-size:38px;letter-spacing:-1px}h2{font-size:24px}nav{font-size:13px}a{color:inherit}section{padding:32px 0;border-bottom:1px solid #ddd}.language,.note{color:#666}.language{font-size:12px;letter-spacing:1px}li{margin:14px 0}.note{font-size:14px}footer{font-size:12px;color:#777;margin-top:30px}</style><main><h1>LimLink</h1><nav>' + nav + '</nav>' + ''.join(sections) + '<footer>Local installation guide · Offline · limlink@floatmax-tech.com</footer></main></html>'
    pathlib.Path(destination).write_text(page, encoding="utf-8")
    return {"guide": str(destination), "languages": len(GUIDES)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    bg = commands.add_parser("background"); bg.add_argument("channel", choices=["Direct"]); bg.add_argument("destination")
    ds = commands.add_parser("layout"); ds.add_argument("mount")
    guide = commands.add_parser("guide"); guide.add_argument("destination")
    args = parser.parse_args()
    if args.command == "background": result = draw_background(args.channel, args.destination)
    elif args.command == "layout": result = write_layout(args.mount)
    else: result = write_guide(args.destination)
    print(json.dumps(result, ensure_ascii=False))
