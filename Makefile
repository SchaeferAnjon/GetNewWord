.PHONY: generate dev test release clean

# 用 XcodeGen 生成 Xcode 项目（brew install xcodegen）
generate:
	@which xcodegen > /dev/null 2>&1 || { echo "请先安装 XcodeGen: brew install xcodegen"; exit 1; }
	xcodegen generate

# 开发版：GetNewWord Dev，数据和正式版分开，从欢迎页开始
dev: generate
	xcodebuild -project GetNewWord.xcodeproj -scheme GetNewWord -configuration Debug -derivedDataPath build/DerivedData build
	open "build/DerivedData/Build/Products/Debug/GetNewWord Dev.app"

# 单元测试：另编一份不签名的开发版放在 build/Test（不动 make dev 那一份），把测试注入进去跑。
# 换一个 bundle id，设置和钥匙串都不和开发版共用；测试时应用只起一个空进程，日志、导出写进临时文件夹
test: generate
	xcodebuild test -project GetNewWord.xcodeproj -scheme GetNewWord -configuration Debug \
	  -derivedDataPath build/Test -destination "platform=macOS,arch=$(shell uname -m)" \
	  CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER=com.getnewword.app.tests.dev

# 正式版：签名、DMG、GitHub Release（不公证；只有维护者能跑，见 scripts/release.sh）
release:
	scripts/release.sh

clean:
	rm -rf GetNewWord.xcodeproj build/
