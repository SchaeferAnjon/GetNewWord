# 打 DMG：build.py <卷名> <输出.dmg> <GetNewWord.app> <卷图标.icns> <background.png>
# 窗口的样子在同目录的 settings.py；scripts/release.sh 用 build/release-tools 里的 Python 跑它。
import os
import sys

import dmgbuild
import dmgbuild.core

# dmgbuild 1.6 除了 icvp 里的背景图 alias，还在 .DS_Store 里写一份 bookmark（pBBk）。
# macOS 15.8 上实测：有 pBBk 时 Finder 打开 DMG 不画背景；不写它，Finder 用 alias，背景正常。
dmgbuild.core.Bookmark.for_file = staticmethod(lambda path: None)

volume, out, app, icon, background = sys.argv[1:]
dmgbuild.build_dmg(
    out,
    volume,
    settings_file=os.path.join(os.path.dirname(os.path.abspath(__file__)), "settings.py"),
    defines={"app": app, "icon": icon, "background": background},
)
