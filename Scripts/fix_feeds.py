import io, re, sys

p = "athena-cloudbuild/Scripts/packages.sh"
src = io.open(p, encoding="utf-8", newline="").read()
lines = src.split("\n")

# 定位 block：从 "# ---- 1. feeds" 注释行到 "./scripts/feeds install -a" 之后
start = next(i for i, l in enumerate(lines) if l.strip().startswith("# ------") and "1. feeds" in l)
end = next(i for i, l in enumerate(lines) if l.strip().startswith("./scripts/feeds install -a"))

new = '''# ---------------------------------------------------------------- 1. feeds
echo "===> [1/6] 接入 feeds：nikki"
grep -q '^src-git nikki ' feeds.conf.default 2>/dev/null || \\
  echo "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" >> feeds.conf.default
cat feeds.conf.default

# 逐个源更新：单个源挂了只剔除它自己，绝不拖死整次构建
while IFS= read -r line; do
  case "$line" in
    src-git*|src-link*)
      read -r _kind _name _rest <<<"$line"
      if ! ./scripts/feeds update "$_name"; then
        echo "WARN: feed '$_name' 更新失败，剔除该源"
        sed -i "/^src-[a-z]*[[:space:]]*$_name[[:space:]]/d" feeds.conf.default
      fi ;;
  esac
done < <(grep -E '^src-(git|link)' feeds.conf.default)

# 目录仍然缺失的源一律剔掉，避免 index 阶段 `find: feeds/xxx` 报错中断
while IFS= read -r line; do
  case "$line" in
    src-git*|src-link*)
      read -r _kind _name _rest <<<"$line"
      if [ ! -d "feeds/$_name" ]; then
        echo "WARN: feeds/$_name 不存在，剔除该源"
        sed -i "/^src-[a-z]*[[:space:]]*$_name[[:space:]]/d" feeds.conf.default
      fi ;;
  esac
done < <(grep -E '^src-(git|link)' feeds.conf.default)
echo "--- feeds.conf.default 最终内容 ---"; cat feeds.conf.default

./scripts/feeds update -a || true
./scripts/feeds install -a || true

# nikki 的三个包必须在 package/ 下可见；install 失败就手工软链
for p in nikki luci-app-nikki luci-i18n-nikki-zh-cn; do
  if [ ! -e "package/feeds/nikki/$p" ] && [ -e "feeds/nikki/$p" ]; then
    mkdir -p package/feeds/nikki
    ln -sfn "../../../feeds/nikki/$p" "package/feeds/nikki/$p"
    echo "FIX: 手工链接 $p"
  fi
done'''

lines[start:end + 1] = new.split("\n")
io.open(p, "w", encoding="utf-8", newline="").write("\n".join(lines))
print("patched lines %d-%d" % (start + 1, end + 1))
