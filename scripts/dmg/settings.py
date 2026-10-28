# dmgbuild 的设置：打开 DMG 看到的窗口。由同目录的 build.py 读进去（scripts/release.sh 调 build.py）。
# dmgbuild 直接写 .DS_Store，不用让 Finder 去摆图标（不要「自动化」权限，也不会弹窗口）。
# 窗口大小和两个图标的位置要和 background.swift 画的箭头对上。window_rect 是含标题栏的整个窗口，
# 所以 640×400 的背景图下面一条会被标题栏的高度挤掉，字要画在上面 370 点以内。
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
# 不设 hide_extensions：它把「隐藏扩展名」写进 App 的 FinderInfo，codesign --verify --strict 就不过了

icon = defines["icon"]  # 卷图标 .VolumeIcon.icns，用 App 的图标
background = defines["background"]  # 同目录的 background@2x.png 会一起合成双分辨率 .tiff

window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {app_name: (160, 180), "Applications": (480, 180)}
