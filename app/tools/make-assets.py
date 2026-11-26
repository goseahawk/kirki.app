#!/usr/bin/env python3
"""Makes the kirki app's images from kirki's own branding (github.com/goseahawk/kirki, at image/kirki.ref):

  app/Resources/AppIcon.icns      the app icon: kirki's icon (the bird on Marigold), on macOS's icon grid
  app/Resources/logo.png          the kirki lockup for dark backgrounds, for the app's own screens
  app/Resources/user-picture.png  the kirki login's picture in the Mac's login window (a square: macOS
                                  shows it as a circle)
  app/Resources/wallpaper.png     the kirki login's Mac desktop picture, seen for a moment while kirki
                                  starts: kirki's dark "Quiet" wallpaper
  app/Resources/fonts/            DM Sans, kirki's typeface (SIL Open Font License)

    python3 app/tools/make-assets.py [KIRKI_CHECKOUT]

Without a checkout, it downloads kirki at image/kirki.ref. Needs rsvg-convert (librsvg) and
ImageMagick's convert. The kirki logo isn't covered by this project's MIT license (see README).
"""
import io, os, shutil, struct, subprocess, sys, tarfile, tempfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RES = os.path.join(ROOT, "app", "Resources")
MARIGOLD = "#f2a93b"


def run(*cmd):
    subprocess.run(cmd, check=True)


def svg(src, dest, width=None, height=None):
    cmd = ["rsvg-convert", src, "-o", dest]
    if width:
        cmd += ["-w", str(width)]
    if height:
        cmd += ["-h", str(height)]
    run(*cmd)


def kirki_checkout(tmp):
    if len(sys.argv) > 1:
        return os.path.abspath(sys.argv[1])
    ref = open(os.path.join(ROOT, "image", "kirki.ref")).read().strip()
    url = f"https://github.com/goseahawk/kirki/archive/{ref}.tar.gz"
    print(f"Downloading kirki {ref[:7]}")
    with urllib.request.urlopen(url) as r:
        tarfile.open(fileobj=io.BytesIO(r.read()), mode="r:gz").extractall(tmp, filter="data")
    return os.path.join(tmp, f"kirki-{ref}")


def icon_png(icon_svg, size, tmp):
    """kirki's icon on macOS's app icon grid: the shape is 824/1024 of the canvas, with a soft shadow."""
    body = round(size * 824 / 1024)
    inner = os.path.join(tmp, f"body-{size}.png")
    out = os.path.join(tmp, f"icon-{size}.png")
    svg(icon_svg, inner, body, body)
    blur = max(1, round(size * 10 / 1024))
    drop = max(1, round(size * 10 / 1024))
    run("convert", "-size", f"{size}x{size}", "xc:none",
        "(", inner, "-background", "black", "-shadow", f"28x{blur}+0+{drop}", ")",
        "-gravity", "center", "-composite",
        inner, "-gravity", "center", "-composite",
        "-define", "png:color-type=6", out)
    return out


def make_icns(icon_svg, dest, tmp):
    # PNG-based icns elements: (type, pixel size)
    types = [(b"icp4", 16), (b"icp5", 32), (b"ic11", 32), (b"icp6", 64), (b"ic12", 64), (b"ic07", 128),
             (b"ic13", 256), (b"ic08", 256), (b"ic14", 512), (b"ic09", 512), (b"ic10", 1024)]
    chunks = []
    for kind, size in types:
        with open(icon_png(icon_svg, size, tmp), "rb") as f:
            png = f.read()
        chunks.append(kind + struct.pack(">I", len(png) + 8) + png)
    body = b"".join(chunks)
    with open(dest, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)


def main():
    for tool in ("rsvg-convert", "convert"):
        if not shutil.which(tool):
            sys.exit(f"Needs {tool} (librsvg / ImageMagick).")
    os.makedirs(os.path.join(RES, "fonts"), exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        kirki = kirki_checkout(tmp)
        build = os.path.join(kirki, "branding", "build")
        installed = os.path.join(kirki, "overlay", "installed")

        make_icns(os.path.join(build, "icon.svg"), os.path.join(RES, "AppIcon.icns"), tmp)
        svg(os.path.join(build, "logo-dark.svg"), os.path.join(RES, "logo.png"), width=746)
        # the login picture: the icon's bird on a full Marigold square
        pic = os.path.join(tmp, "pic.png")
        svg(os.path.join(build, "icon.svg"), pic, 512, 512)
        run("convert", pic, "-background", MARIGOLD, "-flatten", os.path.join(RES, "user-picture.png"))
        svg(os.path.join(installed, "usr/share/wallpapers/kirkus/contents/images_dark/2880x1800.svg"),
            os.path.join(RES, "wallpaper.png"))
        for name in ("DMSans-Regular.ttf", "DMSans-Medium.ttf", "DMSans-Bold.ttf"):
            shutil.copy(os.path.join(installed, "usr/share/fonts/kirkus", name), os.path.join(RES, "fonts", name))
        shutil.copy(os.path.join(installed, "usr/share/licenses/kirkus-fonts/DMSans-OFL.txt"),
                    os.path.join(RES, "fonts", "OFL.txt"))
    for name in sorted(os.listdir(RES)):
        p = os.path.join(RES, name)
        if os.path.isfile(p):
            print(f"  {name}: {os.path.getsize(p)} bytes")


if __name__ == "__main__":
    main()
